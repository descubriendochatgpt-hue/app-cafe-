-- ═══════════════════════════════════════════════════════════════════════════
--  06 · OPERACIONES DE DOMINIO
--
--  Estas funciones son la ÚNICA puerta de escritura al libro. Las políticas
--  RLS de la migración 07 niegan el INSERT directo sobre `movimientos` a todo
--  el mundo; solo estas funciones, que son SECURITY DEFINER, pueden anotar.
--
--  Consecuencia buscada: es imposible escribir en el inventario saltándose la
--  idempotencia, el control de rol o la proyección de saldos. No depende de
--  que nadie se acuerde de usar la capa correcta.
--
--  Todas reciben el operacion_id desde fuera (la PWA lo genera en el móvil,
--  antes de saber si hay cobertura) y todas son idempotentes.
-- ═══════════════════════════════════════════════════════════════════════════

create sequence if not exists pedidos_numero_seq;


/* ─────────────────────────── Apertura de operación ─────────────────────────── */

create or replace function app.abrir_operacion(
  p_operacion_id uuid,
  p_tipo         tipo_operacion,
  p_origen       text,
  p_origen_id    text,
  p_usuario_id   uuid,
  p_ocurrido_en  timestamptz,
  p_datos        jsonb,
  p_nota         text
) returns boolean
language plpgsql
as $$
begin
  insert into operaciones (operacion_id, tipo, origen, origen_id,
                           usuario_id, ocurrido_en, datos, nota)
  values (p_operacion_id, p_tipo, coalesce(p_origen, 'app'), p_origen_id,
          p_usuario_id, coalesce(p_ocurrido_en, now()),
          coalesce(p_datos, '{}'::jsonb), p_nota);
  return true;
exception
  -- Choca contra la clave primaria (reintento de la cola offline) o contra
  -- (origen, origen_id) (reenvío de webhook). Los dos casos son lo mismo:
  -- este hecho ya está contabilizado y no se vuelve a contabilizar.
  when unique_violation then
    return false;
end;
$$;

comment on function app.abrir_operacion is
  'Devuelve cierto solo la primera vez. Reprocesar el mismo hecho nunca '
  'duplica movimientos de stock.';


/* ─────────────────────────── Anotar en el libro ─────────────────────────── */

create or replace function app.anotar(
  p_operacion_id uuid,
  p_lote_id      text,
  p_ubicacion_id text,
  p_cantidad     numeric,
  p_ocurrido_en  timestamptz
) returns bigint
language plpgsql
as $$
declare
  v_sku        text;
  v_unidad     unidad_medida;
  v_id         bigint;
  v_restriccion text;
begin
  select l.sku, a.unidad into v_sku, v_unidad
    from lotes l join articulos a on a.sku = l.sku
   where l.lote_id = p_lote_id;

  if v_sku is null then
    raise exception 'El lote % no existe.', p_lote_id
      using errcode = 'foreign_key_violation';
  end if;

  -- Un paquete es indivisible: media bolsa no es una cantidad.
  if v_unidad = 'UD' and p_cantidad <> trunc(p_cantidad) then
    raise exception 'El artículo % se cuenta en unidades enteras (recibido %).',
      v_sku, p_cantidad using errcode = 'check_violation';
  end if;

  insert into movimientos (operacion_id, sku, lote_id, ubicacion_id, cantidad, ocurrido_en)
  values (p_operacion_id, v_sku, p_lote_id, p_ubicacion_id, p_cantidad, p_ocurrido_en)
  returning movimiento_id into v_id;

  return v_id;
exception
  when check_violation then
    -- El nombre de la restricción, no el texto del mensaje: el texto cambia
    -- con la versión de Postgres y con el idioma del servidor.
    get stacked diagnostics v_restriccion = constraint_name;

    if v_restriccion in ('saldo_nunca_negativo', 'reservado_coherente') then
      raise exception 'No hay stock suficiente del lote % en % (o está reservado).',
        p_lote_id, p_ubicacion_id
        using errcode = 'check_violation', hint = 'stock_insuficiente';
    end if;
    raise;
end;
$$;


/* ─────────────────────────── Identificadores de lote ─────────────────────────── */

create or replace function app.nuevo_lote_id(p_sku text, p_fecha date)
returns text
language plpgsql
as $$
declare
  v_cafe   text;
  v_clase  clase_articulo;
  v_gramos integer;
  v_base   text;
  v_n      integer;
begin
  select a.cafe_id, a.clase, f.gramos
    into v_cafe, v_clase, v_gramos
    from articulos a left join formatos f on f.formato_id = a.formato_id
   where a.sku = p_sku;

  if v_cafe is null then
    raise exception 'El artículo % no existe.', p_sku;
  end if;

  v_base := case v_clase when 'VERDE' then 'VRD' when 'GRANEL' then 'GRN' else 'CAF' end
            || '-' || v_cafe
            || coalesce('-' || v_gramos::text, '')
            || '-' || to_char(p_fecha, 'YYMMDD');

  select count(*) into v_n from lotes where lote_id like v_base || '-%';

  -- Segundo tueste del mismo café, formato y día → sufijo B.
  return v_base || '-' || case when v_n < 26 then chr(65 + v_n) else (v_n + 1)::text end;
end;
$$;


/* ─────────────────────────── Asignación de lote ───────────────────────────
   Cuando nadie escanea (una venta que llega por webhook) hay que decidir de
   qué lote sale la mercancía. La política es por ubicación:

     LOTE_ACTIVO → el lote que dejó el último escaneo de reposición. Si no
                   llega, el resto NO se reparte en silencio: sale como
                   `faltante` y acaba en la pantalla de conciliación.
                   Excepción: si esa ubicación aún no tiene lote activo para
                   ese artículo, se usa FIFO, para que la primera venta tras
                   el alta no se bloquee.
     FIFO        → el más antiguo con saldo. Es lo único posible en el depósito
                   de ECI, cuyas tiendas mezclan lotes y reportan agregado.

   El orden de FIFO es determinista (fecha, luego identificador) porque de él
   depende que reprocesar el histórico dé exactamente el mismo resultado.
   ──────────────────────────────────────────────────────────────── */

create or replace function app.asignar_lotes(
  p_ubicacion_id text,
  p_sku          text,
  p_cantidad     numeric
) returns jsonb
language plpgsql
stable
as $$
declare
  v_politica  politica_lote;
  v_activo    text;
  v_disp      numeric;
  v_resto     numeric := p_cantidad;
  v_toma      numeric;
  v_asignado  jsonb := '[]'::jsonb;
  v_usada     text;
  r           record;
begin
  select politica_lote into v_politica
    from ubicaciones where ubicacion_id = p_ubicacion_id and activo;

  if v_politica is null then
    raise exception 'La ubicación % no existe o está inactiva.', p_ubicacion_id;
  end if;

  v_usada := v_politica::text;

  if v_politica = 'LOTE_ACTIVO' then
    select la.lote_id, coalesce(s.disponible, 0)
      into v_activo, v_disp
      from lote_activo la
      left join saldos s
        on s.lote_id = la.lote_id and s.ubicacion_id = la.ubicacion_id
     where la.ubicacion_id = p_ubicacion_id and la.sku = p_sku;

    if v_activo is not null then
      v_toma := least(greatest(v_disp, 0), v_resto);
      if v_toma > 0 then
        v_asignado := v_asignado ||
          jsonb_build_array(jsonb_build_object('lote_id', v_activo, 'cantidad', v_toma));
        v_resto := v_resto - v_toma;
      end if;
      return jsonb_build_object('asignado', v_asignado,
                                'faltante', v_resto,
                                'politica', v_usada);
    end if;

    -- Sin lote activo declarado todavía: no bloqueamos la venta.
    v_usada := 'FIFO_SIN_LOTE_ACTIVO';
  end if;

  for r in
    select s.lote_id, s.disponible
      from saldos s
      join lotes l on l.lote_id = s.lote_id
     where s.ubicacion_id = p_ubicacion_id
       and s.sku = p_sku
       and s.disponible > 0
     order by coalesce(l.fecha_tostado, l.fecha_recepcion, l.creado_en::date),
              l.lote_id
  loop
    exit when v_resto <= 0;
    v_toma := least(r.disponible, v_resto);
    v_asignado := v_asignado ||
      jsonb_build_array(jsonb_build_object('lote_id', r.lote_id, 'cantidad', v_toma));
    v_resto := v_resto - v_toma;
  end loop;

  return jsonb_build_object('asignado', v_asignado,
                            'faltante', v_resto,
                            'politica', v_usada);
end;
$$;


/* ─────────────────────────── Recepción de café verde ─────────────────────────── */

create or replace function registrar_recepcion_verde(
  p_operacion_id   uuid,
  p_sku            text,
  p_cantidad_kg    numeric,
  p_ubicacion_id   text,
  p_proveedor      text default null,
  p_fecha_recepcion date default null,
  p_precio_kg      numeric default null,
  p_usuario_id     uuid default null,
  p_ocurrido_en    timestamptz default now(),
  p_lote_id        text default null,
  p_nota           text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_lote  text;
  v_fecha date := coalesce(p_fecha_recepcion, (p_ocurrido_en at time zone 'Europe/Madrid')::date);
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para dar de alta café verde.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_cantidad_kg <= 0 then
    raise exception 'Los kilos recibidos tienen que ser positivos.';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'RECEPCION_VERDE', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('sku', p_sku,
                                                'cantidad_kg', p_cantidad_kg,
                                                'ubicacion_id', p_ubicacion_id,
                                                'proveedor', p_proveedor,
                                                'fecha_recepcion', v_fecha,
                                                'precio_kg', p_precio_kg), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  v_lote := coalesce(p_lote_id, app.nuevo_lote_id(p_sku, v_fecha));

  insert into lotes (lote_id, sku, proveedor, fecha_recepcion, precio_kg, notas, creado_por)
  values (v_lote, p_sku, p_proveedor, v_fecha, p_precio_kg, p_nota, p_usuario_id);

  perform app.anotar(p_operacion_id, v_lote, p_ubicacion_id, p_cantidad_kg, p_ocurrido_en);

  update operaciones set datos = datos || jsonb_build_object('lote_id', v_lote)
   where operacion_id = p_operacion_id;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'lote_id', v_lote,
                            'kg', p_cantidad_kg);
end;
$$;


/* ─────────────────────────── Tueste ───────────────────────────
   Una transformación, no dos apuntes sueltos: consume kilos de uno o varios
   sacos de verde y produce paquetes, todo bajo la misma operación y dentro
   de la misma transacción. La merma sale de la diferencia de pesos reales,
   no de un porcentaje configurado, y queda registrada en la operación.

   Admite varios sacos de origen porque la mezcla de la casa son dos.
   ──────────────────────────────────────────────────────────────── */

create or replace function registrar_tueste(
  p_operacion_id uuid,
  p_consumos     jsonb,   -- [{"lote_id":"VRD-…","cantidad": 25.0}]
  p_producciones jsonb,   -- [{"sku":"ETH-250-GR","cantidad": 78, "lote_id": null}]
  p_ubicacion_id text,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_nota         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fecha     date := (p_ocurrido_en at time zone 'Europe/Madrid')::date;
  v_kg_entra  numeric := 0;
  v_kg_sale   numeric := 0;
  v_dias      integer;
  v_lote      text;
  v_gramos    integer;
  v_lotes_out jsonb := '[]'::jsonb;
  c           record;
  p           record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para registrar un tueste.'
      using errcode = 'insufficient_privilege';
  end if;
  if jsonb_array_length(coalesce(p_consumos, '[]'::jsonb)) = 0 then
    raise exception 'Un tueste tiene que consumir café verde.';
  end if;
  if jsonb_array_length(coalesce(p_producciones, '[]'::jsonb)) = 0 then
    raise exception 'Un tueste tiene que producir algo.';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'TUESTE', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('consumos', p_consumos,
                                                'producciones', p_producciones,
                                                'ubicacion_id', p_ubicacion_id), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  -- Sale el verde.
  for c in select * from jsonb_to_recordset(p_consumos) as x(lote_id text, cantidad numeric)
  loop
    if c.cantidad <= 0 then
      raise exception 'Los kilos consumidos del lote % tienen que ser positivos.', c.lote_id;
    end if;
    perform app.anotar(p_operacion_id, c.lote_id, p_ubicacion_id, -c.cantidad, p_ocurrido_en);
    v_kg_entra := v_kg_entra + c.cantidad;
  end loop;

  v_dias := app.parametro_int('dias_consumo_preferente', 365);

  -- Entra el tostado.
  for p in select * from jsonb_to_recordset(p_producciones)
                     as x(sku text, cantidad numeric, lote_id text)
  loop
    if p.cantidad <= 0 then
      raise exception 'Las unidades producidas de % tienen que ser positivas.', p.sku;
    end if;

    select f.gramos into v_gramos
      from articulos a join formatos f on f.formato_id = a.formato_id
     where a.sku = p.sku;

    if v_gramos is null then
      raise exception 'El artículo % no es un paquete con formato.', p.sku;
    end if;

    v_lote := coalesce(p.lote_id, app.nuevo_lote_id(p.sku, v_fecha));

    insert into lotes (lote_id, sku, fecha_tostado, fecha_consumo_preferente,
                       notas, creado_por)
    values (v_lote, p.sku, v_fecha, v_fecha + v_dias, p_nota, p_usuario_id);

    perform app.anotar(p_operacion_id, v_lote, p_ubicacion_id, p.cantidad, p_ocurrido_en);

    -- Ascendencia: de qué sacos salió este lote, repartida a prorrata.
    insert into lote_composicion (lote_hijo_id, lote_padre_id, cantidad)
    select v_lote, c2.lote_id, round(c2.cantidad * (p.cantidad * v_gramos / 1000.0)
           / nullif(v_kg_entra, 0), 3)
      from jsonb_to_recordset(p_consumos) as c2(lote_id text, cantidad numeric)
    on conflict do nothing;

    v_kg_sale := v_kg_sale + (p.cantidad * v_gramos / 1000.0);
    v_lotes_out := v_lotes_out ||
      jsonb_build_array(jsonb_build_object('lote_id', v_lote, 'sku', p.sku,
                                           'cantidad', p.cantidad));
  end loop;

  update operaciones
     set datos = datos || jsonb_build_object(
           'producciones', v_lotes_out,
           'kg_verde', v_kg_entra,
           'kg_tostado', round(v_kg_sale, 3),
           'merma_pct', round((v_kg_entra - v_kg_sale) / nullif(v_kg_entra, 0) * 100, 2),
           'lotes', v_lotes_out)
   where operacion_id = p_operacion_id;

  return jsonb_build_object(
    'idempotente', false,
    'operacion_id', p_operacion_id,
    'lotes', v_lotes_out,
    'kg_verde', v_kg_entra,
    'kg_tostado', round(v_kg_sale, 3),
    'merma_pct', round((v_kg_entra - v_kg_sale) / nullif(v_kg_entra, 0) * 100, 2));
end;
$$;


/* ─────────────────────────── Traslado ───────────────────────────
   Servir a El Corte Inglés es esto y no una venta: la mercancía cambia de
   sitio, sigue siendo nuestra y el stock total no baja. Además, el traslado
   deja marcado el lote activo en el destino, que es lo que convierte el
   escaneo de reposición en la declaración que luego usan los webhooks.
   ──────────────────────────────────────────────────────────────── */

create or replace function registrar_traslado(
  p_operacion_id uuid,
  p_lote_id      text,
  p_origen_ubicacion  text,
  p_destino_ubicacion text,
  p_cantidad     numeric,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_nota         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sku text;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para mover mercancía.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_origen_ubicacion = p_destino_ubicacion then
    raise exception 'El origen y el destino del traslado son el mismo sitio.';
  end if;
  if p_cantidad <= 0 then
    raise exception 'La cantidad trasladada tiene que ser positiva.';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'TRASLADO', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('lote_id', p_lote_id,
                                                'de', p_origen_ubicacion,
                                                'a', p_destino_ubicacion,
                                                'cantidad', p_cantidad), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  select sku into v_sku from lotes where lote_id = p_lote_id;

  perform app.anotar(p_operacion_id, p_lote_id, p_origen_ubicacion,  -p_cantidad, p_ocurrido_en);
  perform app.anotar(p_operacion_id, p_lote_id, p_destino_ubicacion,  p_cantidad, p_ocurrido_en);

  -- El gesto físico de reponer ES la declaración del lote activo.
  insert into lote_activo (ubicacion_id, sku, lote_id, desde, operacion_id)
  values (p_destino_ubicacion, v_sku, p_lote_id, p_ocurrido_en, p_operacion_id)
  on conflict (ubicacion_id, sku) do update
    set lote_id = excluded.lote_id,
        desde = excluded.desde,
        operacion_id = excluded.operacion_id;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'sku', v_sku,
                            'lote_activo_en_destino', p_lote_id);
end;
$$;


/* ─────────────────────────── Venta ─────────────────────────── */

create or replace function registrar_venta(
  p_operacion_id uuid,
  p_ubicacion_id text,
  p_lineas       jsonb,   -- [{"sku":…, "cantidad":…, "lote_id":opcional, "precio_unit":…}]
  p_canal        text default 'Mostrador',
  p_cliente_id   uuid default null,
  p_origen       text default 'app',
  p_origen_id    text default null,
  p_documento_fiscal text default null,
  p_documento_fiscal_sistema text default null,
  p_forma_pago   text default null,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_evento_id    uuid default null,
  p_nota         text default null,
  p_permitir_faltante boolean default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido    uuid;
  v_numero    text;
  v_permite   boolean;
  v_asig      jsonb;
  v_linea     uuid;
  v_precio    numeric;
  v_importe   numeric;
  v_base      numeric := 0;
  v_servidas  numeric;
  v_faltante  numeric;
  v_incid     jsonb := '[]'::jsonb;
  v_iva_pct   numeric := 21;
  v_permitir  boolean;
  l           record;
  a           record;
begin
  -- Una venta que llega de Loyverse o de WooCommerce YA ha ocurrido en el
  -- mundo real: negarse a registrarla no devuelve el café al estante, solo
  -- pierde el dato. Se anota lo que había y la diferencia va a conciliación.
  --
  -- Una venta que se está tecleando en el mostrador todavía no ha ocurrido:
  -- ahí lo correcto es fallar y que el empleado lo sepa antes de cobrar.
  v_permitir := coalesce(p_permitir_faltante, coalesce(p_origen, 'app') <> 'app');
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para registrar una venta.'
      using errcode = 'insufficient_privilege';
  end if;

  select permite_venta into v_permite
    from ubicaciones where ubicacion_id = p_ubicacion_id and activo;
  if v_permite is null then
    raise exception 'La ubicación % no existe o está inactiva.', p_ubicacion_id;
  end if;
  if not v_permite then
    raise exception 'Desde % no se vende: la salida de ahí es un traslado.', p_ubicacion_id;
  end if;

  if not app.abrir_operacion(p_operacion_id, 'VENTA', p_origen, p_origen_id,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('lineas', p_lineas,
                                                'canal', p_canal,
                                                'ubicacion_id', p_ubicacion_id,
                                                'cliente_id', p_cliente_id,
                                                'forma_pago', p_forma_pago,
                                                'documento_fiscal', p_documento_fiscal,
                                                'documento_fiscal_sistema',
                                                  p_documento_fiscal_sistema), p_nota) then
    return jsonb_build_object(
      'idempotente', true,
      'operacion_id', p_operacion_id,
      'pedido_id', (select pedido_id from pedidos
                     where operacion_id = p_operacion_id
                        or (origen = p_origen and origen_id = p_origen_id
                            and p_origen_id is not null)
                     limit 1));
  end if;

  v_numero := 'PED-' || to_char(p_ocurrido_en, 'YYYY') || '-' ||
              lpad(nextval('pedidos_numero_seq')::text, 5, '0');

  insert into pedidos (pedido_id, numero, operacion_id, cliente_id, canal, ubicacion_id,
                       estado, fecha, origen, origen_id,
                       documento_fiscal, documento_fiscal_sistema,
                       iva_pct, forma_pago, notas, creado_por)
  values (gen_random_uuid(), v_numero, p_operacion_id, p_cliente_id, p_canal, p_ubicacion_id,
          'ENTREGADO', (p_ocurrido_en at time zone 'Europe/Madrid')::date,
          p_origen, p_origen_id, p_documento_fiscal, p_documento_fiscal_sistema,
          v_iva_pct, p_forma_pago, p_nota, p_usuario_id)
  returning pedido_id into v_pedido;

  for l in select * from jsonb_to_recordset(p_lineas)
                    as x(sku text, cantidad numeric, lote_id text,
                         precio_unit numeric, dto_pct numeric)
  loop
    if l.cantidad <= 0 then
      raise exception 'La cantidad vendida de % tiene que ser positiva.', l.sku;
    end if;

    -- El precio lo pone el canal, que es quien ha cobrado. Si no viene
    -- (venta de mostrador desde el escáner), se toma el de tarifa.
    v_precio := coalesce(l.precio_unit,
                         (select precio_venta from precios where sku = l.sku), 0);
    v_importe := round(v_precio * l.cantidad * (1 - coalesce(l.dto_pct, 0) / 100), 2);
    v_base := v_base + v_importe;

    insert into pedido_lineas (pedido_id, sku, cantidad, precio_unit, dto_pct, importe)
    values (v_pedido, l.sku, l.cantidad, v_precio, coalesce(l.dto_pct, 0), v_importe)
    returning linea_id into v_linea;

    if l.lote_id is not null then
      -- El operario ha escaneado la bolsa: no hay nada que deducir.
      perform app.anotar(p_operacion_id, l.lote_id, p_ubicacion_id, -l.cantidad, p_ocurrido_en);
      v_servidas := l.cantidad;
      v_faltante := 0;
    else
      v_asig := app.asignar_lotes(p_ubicacion_id, l.sku, l.cantidad);
      v_faltante := (v_asig ->> 'faltante')::numeric;
      v_servidas := l.cantidad - v_faltante;

      for a in select * from jsonb_to_recordset(v_asig -> 'asignado')
                         as y(lote_id text, cantidad numeric)
      loop
        perform app.anotar(p_operacion_id, a.lote_id, p_ubicacion_id, -a.cantidad, p_ocurrido_en);
      end loop;

      if v_faltante > 0 and not v_permitir then
        raise exception 'No hay stock suficiente de % en %: faltan % de %.',
          l.sku, p_ubicacion_id, v_faltante, l.cantidad
          using errcode = 'check_violation', hint = 'stock_insuficiente';
      end if;

      if v_faltante > 0 then
        -- No se inventa stock ni se descarta la venta: queda anotado lo que
        -- sí había y la diferencia va a la pantalla de conciliación, con el
        -- canal y el evento que la originaron.
        v_incid := v_incid || jsonb_build_array(app.abrir_incidencia(
          case when (v_asig ->> 'politica') = 'LOTE_ACTIVO'
               then 'LOTE_SIN_RESOLVER' else 'STOCK_INSUFICIENTE' end,
          p_origen, coalesce(p_origen_id, v_numero),
          jsonb_build_object('sku', l.sku, 'ubicacion', p_ubicacion_id,
                             'pedida', l.cantidad, 'servida', v_servidas,
                             'faltante', v_faltante, 'politica', v_asig ->> 'politica'),
          p_operacion_id, p_evento_id));
      end if;
    end if;

    update pedido_lineas set servidas = v_servidas where linea_id = v_linea;
  end loop;

  update pedidos
     set base  = round(v_base / (1 + v_iva_pct / 100), 2),
         iva   = round(v_base - v_base / (1 + v_iva_pct / 100), 2),
         total = round(v_base, 2),
         estado = (case when jsonb_array_length(v_incid) > 0
                        then 'SERVIDO' else 'ENTREGADO' end)::estado_pedido
   where pedido_id = v_pedido;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'pedido_id', v_pedido,
                            'numero', v_numero,
                            'total', round(v_base, 2),
                            'incidencias', v_incid);
end;
$$;

/* ─────────────────────────── Movimiento suelto ───────────────────────────
   Entradas, salidas y mermas sin origen comercial: muestras, autoconsumo,
   roturas, devoluciones. Sigue siendo una operación idempotente.
   ──────────────────────────────────────────────────────────────── */

create or replace function registrar_movimiento(
  p_operacion_id uuid,
  p_tipo         tipo_operacion,
  p_lote_id      text,
  p_ubicacion_id text,
  p_cantidad     numeric,      -- siempre positiva; el signo lo pone el tipo
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_nota         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signo int;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para mover stock.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_tipo not in ('ENTRADA', 'SALIDA', 'MERMA', 'DEVOLUCION') then
    raise exception 'registrar_movimiento no admite el tipo %. Usa la función específica.', p_tipo;
  end if;
  if p_cantidad <= 0 then
    raise exception 'La cantidad tiene que ser positiva: el signo lo decide el tipo de operación.';
  end if;

  v_signo := case when p_tipo in ('SALIDA', 'MERMA') then -1 else 1 end;

  if not app.abrir_operacion(p_operacion_id, p_tipo, 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('lote_id', p_lote_id,
                                                'ubicacion', p_ubicacion_id,
                                                'cantidad', p_cantidad), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  perform app.anotar(p_operacion_id, p_lote_id, p_ubicacion_id,
                     v_signo * p_cantidad, p_ocurrido_en);

  -- Una entrada también repone: deja el lote activo puesto en esa ubicación.
  if v_signo > 0 then
    insert into lote_activo (ubicacion_id, sku, lote_id, desde, operacion_id)
    select p_ubicacion_id, sku, p_lote_id, p_ocurrido_en, p_operacion_id
      from lotes where lote_id = p_lote_id
    on conflict (ubicacion_id, sku) do update
      set lote_id = excluded.lote_id, desde = excluded.desde,
          operacion_id = excluded.operacion_id;
  end if;

  return jsonb_build_object('idempotente', false, 'operacion_id', p_operacion_id);
end;
$$;


/* ─────────────────────────── Recuento físico ───────────────────────────
   Un inventario no sobrescribe el stock: genera los ajustes que explican la
   diferencia. El descuadre queda en el libro, con su fecha y su responsable,
   en vez de desaparecer.
   ──────────────────────────────────────────────────────────────── */

create or replace function registrar_ajuste_inventario(
  p_operacion_id uuid,
  p_ubicacion_id text,
  p_recuento     jsonb,   -- [{"lote_id":"CAF-…","contado": 37}]
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_nota         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_teorico numeric;
  v_dif     numeric;
  v_ajustes jsonb := '[]'::jsonb;
  r         record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para hacer un recuento.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'AJUSTE', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('ubicacion', p_ubicacion_id,
                                                'recuento', p_recuento), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for r in select * from jsonb_to_recordset(p_recuento) as x(lote_id text, contado numeric)
  loop
    select coalesce(cantidad, 0) into v_teorico
      from saldos where lote_id = r.lote_id and ubicacion_id = p_ubicacion_id;

    v_dif := r.contado - coalesce(v_teorico, 0);
    continue when v_dif = 0;

    perform app.anotar(p_operacion_id, r.lote_id, p_ubicacion_id, v_dif, p_ocurrido_en);

    v_ajustes := v_ajustes || jsonb_build_array(jsonb_build_object(
      'lote_id', r.lote_id, 'teorico', coalesce(v_teorico, 0),
      'contado', r.contado, 'diferencia', v_dif));
  end loop;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'ajustes', v_ajustes);
end;
$$;


/* ─────────────────────────── Reservas ───────────────────────────
   Confirmar un pedido compromete el stock; servirlo lo descuenta. Entre esos
   dos momentos la mercancía sigue en el libro, pero deja de estar disponible
   para otro canal. Es lo que evita vender dos veces el mismo paquete desde
   la web y desde el mercado.
   ──────────────────────────────────────────────────────────────── */

create or replace function reservar_pedido(
  p_operacion_id uuid,
  p_pedido_id    uuid,
  p_ubicacion_id text,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_asig    jsonb;
  v_reservas jsonb := '[]'::jsonb;
  v_falta   numeric;
  v_incid   jsonb := '[]'::jsonb;
  l         record;
  a         record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para reservar stock.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'RESERVA', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id), null) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for l in select linea_id, sku, cantidad - servidas as pendiente
             from pedido_lineas where pedido_id = p_pedido_id and cantidad > servidas
  loop
    v_asig := app.asignar_lotes(p_ubicacion_id, l.sku, l.pendiente);
    v_falta := (v_asig ->> 'faltante')::numeric;

    for a in select * from jsonb_to_recordset(v_asig -> 'asignado')
                       as y(lote_id text, cantidad numeric)
    loop
      insert into reservas (operacion_id, pedido_id, linea_id, sku,
                            lote_id, ubicacion_id, cantidad)
      values (p_operacion_id, p_pedido_id, l.linea_id, l.sku,
              a.lote_id, p_ubicacion_id, a.cantidad);

      -- Reservar no saca nada del libro: marca la parte comprometida.
      update saldos set reservado = reservado + a.cantidad, actualizado_en = now()
       where lote_id = a.lote_id and ubicacion_id = p_ubicacion_id;

      v_reservas := v_reservas || jsonb_build_array(
        jsonb_build_object('lote_id', a.lote_id, 'cantidad', a.cantidad));
    end loop;

    if v_falta > 0 then
      v_incid := v_incid || jsonb_build_array(app.abrir_incidencia(
        'STOCK_INSUFICIENTE', 'app', p_pedido_id::text,
        jsonb_build_object('sku', l.sku, 'faltante', v_falta),
        p_operacion_id, null));
    end if;
  end loop;

  update pedidos set estado = 'CONFIRMADO'
   where pedido_id = p_pedido_id and estado = 'BORRADOR';

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'reservas', v_reservas,
                            'incidencias', v_incid);
end;
$$;

create or replace function servir_reservas_pedido(
  p_operacion_id uuid,
  p_pedido_id    uuid,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total numeric := 0;
  r       record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para servir un pedido.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'VENTA', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id,
                                                'desde', 'reservas'), null) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for r in select * from reservas
            where pedido_id = p_pedido_id and estado = 'ACTIVA'
            order by reserva_id
  loop
    -- Primero se suelta la reserva y después se anota la salida. En el otro
    -- orden, la restricción reservado <= cantidad rechazaría el movimiento.
    update saldos set reservado = reservado - r.cantidad, actualizado_en = now()
     where lote_id = r.lote_id and ubicacion_id = r.ubicacion_id;

    perform app.anotar(p_operacion_id, r.lote_id, r.ubicacion_id, -r.cantidad, p_ocurrido_en);

    update reservas set estado = 'SERVIDA', cerrado_en = now()
     where reserva_id = r.reserva_id;

    update pedido_lineas set servidas = servidas + r.cantidad
     where linea_id = r.linea_id;

    v_total := v_total + r.cantidad;
  end loop;

  update pedidos set estado = 'SERVIDO' where pedido_id = p_pedido_id;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'unidades', v_total);
end;
$$;

create or replace function liberar_reservas_pedido(
  p_operacion_id uuid,
  p_pedido_id    uuid,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n int := 0;
  r   record;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para liberar reservas.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'LIBERACION', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id), null) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for r in select * from reservas where pedido_id = p_pedido_id and estado = 'ACTIVA'
  loop
    update saldos set reservado = reservado - r.cantidad, actualizado_en = now()
     where lote_id = r.lote_id and ubicacion_id = r.ubicacion_id;
    update reservas set estado = 'LIBERADA', cerrado_en = now()
     where reserva_id = r.reserva_id;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id, 'liberadas', v_n);
end;
$$;
