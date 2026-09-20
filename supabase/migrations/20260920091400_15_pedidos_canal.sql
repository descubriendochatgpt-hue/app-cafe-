-- ═══════════════════════════════════════════════════════════════════════════
--  15 · PEDIDOS QUE LLEGAN DE UN CANAL
--
--  Una venta de mostrador y un pedido web no son lo mismo y no pueden
--  tratarse igual:
--
--    Mostrador → el cliente se lleva el café. Sale del stock y se acabó.
--    Web       → hay un hueco entre que se paga y que se envía. Durante ese
--                hueco la mercancía sigue en el almacén, pero ya no es
--                vendible por otro canal.
--
--  De ahí la reserva: confirmar compromete, servir descuenta. Sin eso, el
--  mismo último paquete se puede vender por la web y en un mercado el mismo
--  sábado, y uno de los dos clientes se queda sin café.
-- ═══════════════════════════════════════════════════════════════════════════

/* Datos propios de cada canal para el mapeo: en WooCommerce hace falta saber
   si un código es un producto simple o una variación, y de qué producto
   cuelga, porque la API para actualizar el stock es distinta. */
alter table mapeo_articulos add column if not exists datos jsonb not null default '{}'::jsonb;

/* Marca de lo último publicado en cada canal, para no reescribir en el
   sistema ajeno un stock que no ha cambiado. Con 20-30 referencias no es un
   problema de rendimiento: es no llenar el registro de cambios de la tienda
   con ruido que oculte los cambios de verdad. */
create table stock_publicado (
  canal        text not null check (canal in ('woocommerce', 'loyverse')),
  sku          text not null references articulos (sku) on update cascade,
  cantidad     numeric(14,3) not null,
  publicado_en timestamptz not null default now(),
  primary key (canal, sku)
);

grant select on stock_publicado to authenticated;


/* ─────────────────────────── Alta del pedido ─────────────────────────── */

create or replace function registrar_pedido_canal(
  p_operacion_id uuid,
  p_ubicacion_id text,
  p_lineas       jsonb,   -- [{"sku":…, "cantidad":…, "precio_unit":…}]
  p_canal        text,
  p_origen       text,
  p_origen_id    text,
  p_cliente_id   uuid default null,
  p_documento_fiscal text default null,
  p_documento_fiscal_sistema text default null,
  p_forma_pago   text default null,
  p_ocurrido_en  timestamptz default now(),
  p_nota         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido   uuid;
  v_numero   text;
  v_linea    uuid;
  v_precio   numeric;
  v_importe  numeric;
  v_base     numeric := 0;
  v_iva      numeric := app.parametro_int('iva_por_defecto', 21);
  v_asig     jsonb;
  v_falta    numeric;
  v_reservas jsonb := '[]'::jsonb;
  v_incid    jsonb := '[]'::jsonb;
  l          record;
  a          record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para registrar un pedido.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'RESERVA', p_origen, p_origen_id,
                             null, p_ocurrido_en,
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
                     where origen = p_origen and origen_id = p_origen_id limit 1));
  end if;

  v_numero := 'PED-' || to_char(p_ocurrido_en, 'YYYY') || '-' ||
              lpad(nextval('pedidos_numero_seq')::text, 5, '0');

  insert into pedidos (pedido_id, numero, operacion_id, cliente_id, canal, ubicacion_id,
                       estado, fecha, origen, origen_id,
                       documento_fiscal, documento_fiscal_sistema,
                       iva_pct, forma_pago, notas)
  values (gen_random_uuid(), v_numero, p_operacion_id, p_cliente_id, p_canal, p_ubicacion_id,
          'CONFIRMADO', (p_ocurrido_en at time zone 'Europe/Madrid')::date,
          p_origen, p_origen_id, p_documento_fiscal, p_documento_fiscal_sistema,
          v_iva, p_forma_pago, p_nota)
  returning pedido_id into v_pedido;

  for l in select * from jsonb_to_recordset(p_lineas)
                    as x(sku text, cantidad numeric, precio_unit numeric, dto_pct numeric)
  loop
    if l.cantidad <= 0 then
      raise exception 'La cantidad de % tiene que ser positiva.', l.sku;
    end if;

    v_precio := coalesce(l.precio_unit, (select precio_venta from precios where sku = l.sku), 0);
    v_importe := round(v_precio * l.cantidad * (1 - coalesce(l.dto_pct, 0) / 100), 2);
    v_base := v_base + v_importe;

    insert into pedido_lineas (pedido_id, sku, cantidad, precio_unit, dto_pct, importe)
    values (v_pedido, l.sku, l.cantidad, v_precio, coalesce(l.dto_pct, 0), v_importe)
    returning linea_id into v_linea;

    -- Se compromete el stock, pero NO sale del libro: la mercancía sigue en
    -- el almacén hasta que se envía.
    v_asig := app.asignar_lotes(p_ubicacion_id, l.sku, l.cantidad);
    v_falta := (v_asig ->> 'faltante')::numeric;

    for a in select * from jsonb_to_recordset(v_asig -> 'asignado')
                       as y(lote_id text, cantidad numeric)
    loop
      insert into reservas (operacion_id, pedido_id, linea_id, sku,
                            lote_id, ubicacion_id, cantidad)
      values (p_operacion_id, v_pedido, v_linea, l.sku, a.lote_id, p_ubicacion_id, a.cantidad);

      update saldos set reservado = reservado + a.cantidad, actualizado_en = now()
       where lote_id = a.lote_id and ubicacion_id = p_ubicacion_id;

      v_reservas := v_reservas || jsonb_build_array(
        jsonb_build_object('lote_id', a.lote_id, 'cantidad', a.cantidad));
    end loop;

    -- El pedido ya está pagado en la tienda: negarse no devuelve el café al
    -- estante. Se reserva lo que hay y la diferencia va a conciliación, que
    -- es donde alguien puede decidir si se envía tarde o se reembolsa.
    if v_falta > 0 then
      v_incid := v_incid || jsonb_build_array(app.abrir_incidencia(
        'STOCK_INSUFICIENTE', p_origen, p_origen_id,
        jsonb_build_object('sku', l.sku, 'pedida', l.cantidad, 'reservada', l.cantidad - v_falta,
                           'faltante', v_falta, 'ubicacion', p_ubicacion_id),
        p_operacion_id, null));
    end if;
  end loop;

  update pedidos
     set base  = round(v_base / (1 + v_iva / 100), 2),
         iva   = round(v_base - v_base / (1 + v_iva / 100), 2),
         total = round(v_base, 2)
   where pedido_id = v_pedido;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'pedido_id', v_pedido,
                            'numero', v_numero,
                            'reservas', v_reservas,
                            'incidencias', v_incid);
end;
$$;


/* ─────────────────────────── Servir el pedido ───────────────────────────
   Se reemplaza la versión de la migración 06 para que pueda dejar constancia
   del canal y del identificador de origen. Hace falta para que una devolución
   posterior encuentre de qué lotes salió la mercancía.
   ──────────────────────────────────────────────────────────────── */

drop function if exists servir_reservas_pedido(uuid, uuid, uuid, timestamptz);

create or replace function servir_reservas_pedido(
  p_operacion_id uuid,
  p_pedido_id    uuid,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_origen       text default 'app',
  p_origen_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total  numeric := 0;
  v_origen text;
  v_ref    text;
  r        record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para servir un pedido.'
      using errcode = 'insufficient_privilege';
  end if;

  -- Se guarda el pedido en términos del CANAL, no por su identificador
  -- interno. Al reproducir el histórico sobre una base vacía los uuid son
  -- otros, y sin esta referencia el envío no se podría volver a casar con
  -- su pedido.
  select origen, origen_id into v_origen, v_ref
    from pedidos where pedido_id = p_pedido_id;

  if not app.abrir_operacion(p_operacion_id, 'VENTA', p_origen, p_origen_id,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id,
                                                'desde', 'reservas',
                                                'pedido_origen', v_origen,
                                                'pedido_origen_id', v_ref), null) then
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

/* Busca el pedido que creó un canal. Los conectores trabajan con el
   identificador del sistema de origen, no con el nuestro. */
create or replace function pedido_de_canal(p_origen text, p_origen_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse.' using errcode = 'insufficient_privilege';
  end if;

  select jsonb_build_object(
           'pedido_id', p.pedido_id, 'numero', p.numero, 'estado', p.estado,
           'ubicacion_id', p.ubicacion_id,
           'reservas_activas', (select count(*) from reservas r
                                 where r.pedido_id = p.pedido_id and r.estado = 'ACTIVA'),
           'servidas', (select coalesce(sum(servidas), 0) from pedido_lineas
                         where pedido_id = p.pedido_id))
    into v
    from pedidos p
   where p.origen = p_origen and p.origen_id = p_origen_id;

  return v;
end;
$$;

grant execute on function
  registrar_pedido_canal(uuid, text, jsonb, text, text, text, uuid, text, text, text, timestamptz, text),
  servir_reservas_pedido(uuid, uuid, uuid, timestamptz, text, text),
  pedido_de_canal(text, text)
to authenticated;


/* Liberar también deja la referencia del canal, por la misma razón que
   servir: al reproducir el histórico hay que saber qué pedido era. */
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
  v_n      int := 0;
  v_origen text;
  v_ref    text;
  r        record;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para liberar reservas.'
      using errcode = 'insufficient_privilege';
  end if;

  select origen, origen_id into v_origen, v_ref
    from pedidos where pedido_id = p_pedido_id;

  if not app.abrir_operacion(p_operacion_id, 'LIBERACION', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id,
                                                'pedido_origen', v_origen,
                                                'pedido_origen_id', v_ref), null) then
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

  update pedidos set estado = 'CANCELADO'
   where pedido_id = p_pedido_id and estado in ('BORRADOR', 'CONFIRMADO');

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id, 'liberadas', v_n);
end;
$$;
