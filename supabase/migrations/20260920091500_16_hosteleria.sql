-- ═══════════════════════════════════════════════════════════════════════════
--  16 · HOSTELERÍA · PEDIDOS POR ENLACE
--
--  Bares y cafeterías piden por WhatsApp. De las dos opciones que se
--  plantearon, esta es la recomendada: un formulario que se manda por enlace,
--  en vez de la Cloud API de WhatsApp.
--
--  Por qué:
--    · no hay coste por conversación ni aprobación de Meta que esperar;
--    · no hay que interpretar lenguaje natural, que es donde se equivocaría:
--      «ponme 3 de la mezcla» no dice el formato, y «lo de siempre» no dice
--      nada. Un desplegable no se equivoca;
--    · el cliente no instala nada: abre un enlace y pide.
--
--  Cada cliente tiene SU enlace, que se puede revocar sin afectar a los demás.
--  El enlace es la credencial, así que no se puede adivinar y se puede
--  cambiar en un segundo si acaba donde no debe.
-- ═══════════════════════════════════════════════════════════════════════════

alter table clientes
  add column if not exists token_pedido text,
  add column if not exists token_creado_en timestamptz;

create unique index if not exists clientes_token_unico
  on clientes (token_pedido) where token_pedido is not null;

comment on column clientes.token_pedido is
  'Credencial del enlace de pedido. Quien la tiene puede pedir en nombre de '
  'este cliente, así que se genera al azar y se puede revocar.';

insert into parametros (clave, valor, descripcion) values
  ('hosteleria_ubicacion', 'ALMACEN',
   'Ubicación desde la que se reservan los pedidos de hostelería'),
  ('hosteleria_pedidos_max_hora', '5',
   'Pedidos que admite un mismo enlace por hora. Freno a envíos repetidos por error'),
  ('hosteleria_whatsapp', '',
   'Teléfono del tostador, en formato internacional sin signos, para el botón de avisar'),
  ('hosteleria_mensaje', 'Gracias por tu pedido. Te avisamos en cuanto salga.',
   'Mensaje que ve el cliente al terminar')
on conflict (clave) do nothing;


/* ─────────────────────────── Gestión del enlace ─────────────────────────── */

create or replace function generar_enlace_pedido(p_cliente_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_token text;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para generar un enlace.'
      using errcode = 'insufficient_privilege';
  end if;

  -- 32 caracteres al azar: no se adivina probando.
  v_token := encode(gen_random_bytes(16), 'hex');

  update clientes
     set token_pedido = v_token, token_creado_en = now()
   where cliente_id = p_cliente_id and activo;

  if not found then
    raise exception 'Ese cliente no existe o está dado de baja.';
  end if;

  return v_token;
end;
$$;

create or replace function revocar_enlace_pedido(p_cliente_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para revocar un enlace.'
      using errcode = 'insufficient_privilege';
  end if;

  update clientes set token_pedido = null, token_creado_en = null
   where cliente_id = p_cliente_id;

  return found;
end;
$$;


/* ─────────────────────────── Lo que ve el cliente ───────────────────────────
   Se devuelve el catálogo con SU precio, ya con su descuento habitual
   aplicado. El cliente no ve costes, ni márgenes, ni stock de otros sitios:
   solo lo que puede pedir y a cuánto le sale.
   ──────────────────────────────────────────────────────────────── */

create or replace function catalogo_pedido(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_cliente  record;
  v_ubicacion text := app.parametro('hosteleria_ubicacion', 'ALMACEN');
  v_articulos jsonb;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then
    return null;
  end if;

  select cliente_id, nombre, descuento_pct into v_cliente
    from clientes where token_pedido = p_token and activo;

  if v_cliente.cliente_id is null then
    -- Enlace revocado, cliente de baja o token inventado: la misma respuesta
    -- para los tres, para no decirle a nadie cuál de las tres es.
    return null;
  end if;

  select coalesce(jsonb_agg(x order by x ->> 'cafe', x ->> 'formato'), '[]'::jsonb)
    into v_articulos
    from (
      select jsonb_build_object(
               'sku', a.sku,
               'cafe', c.nombre,
               'origen', c.origen,
               'perfil_tueste', c.perfil_tueste,
               'formato', f.nombre,
               'gramos', f.gramos,
               'molienda', f.molienda,
               'precio', round(coalesce(pr.precio_venta, 0)
                               * (1 - v_cliente.descuento_pct / 100), 2),
               'disponible', coalesce((select sum(s.disponible) from saldos s
                                        where s.sku = a.sku
                                          and s.ubicacion_id = v_ubicacion), 0)
             ) as x
        from articulos a
        join cafes c    on c.cafe_id = a.cafe_id
        join formatos f on f.formato_id = a.formato_id
        left join precios pr on pr.sku = a.sku
       where a.clase = 'PAQUETE' and a.activo and c.activo and f.activo
         and coalesce(pr.precio_venta, 0) > 0
    ) z;

  return jsonb_build_object(
    'cliente', jsonb_build_object('nombre', v_cliente.nombre,
                                  'descuento_pct', v_cliente.descuento_pct),
    'articulos', v_articulos,
    'mensaje_final', app.parametro('hosteleria_mensaje', ''),
    'whatsapp', app.parametro('hosteleria_whatsapp', ''));
end;
$$;


/* ─────────────────────────── Alta del pedido ─────────────────────────── */

create or replace function crear_pedido_hosteleria(
  p_operacion_id uuid,
  p_token        text,
  p_lineas       jsonb,   -- [{"sku":…, "cantidad":…}]
  p_nota         text default null,
  p_ocurrido_en  timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cliente   uuid;
  v_nombre    text;
  v_descuento numeric;
  v_ubicacion text := app.parametro('hosteleria_ubicacion', 'ALMACEN');
  v_maximo    int  := app.parametro_int('hosteleria_pedidos_max_hora', 5);
  v_recientes int;
  v_lineas    jsonb;
  r           jsonb;
begin
  select cliente_id, nombre, descuento_pct into v_cliente, v_nombre, v_descuento
    from clientes where token_pedido = p_token and activo;

  if v_cliente is null then
    raise exception 'El enlace no es válido o ha sido revocado.'
      using errcode = 'insufficient_privilege';
  end if;

  if jsonb_array_length(coalesce(p_lineas, '[]'::jsonb)) = 0 then
    raise exception 'El pedido está vacío.';
  end if;

  -- Freno a los envíos repetidos. No es tanto contra un ataque como contra
  -- el doble clic y el «no sé si se ha enviado» que lo manda tres veces.
  select count(*) into v_recientes
    from pedidos
   where cliente_id = v_cliente
     and origen = 'app'
     and canal = 'Hostelería'
     and creado_en > now() - interval '1 hour';

  if v_recientes >= v_maximo then
    raise exception 'Se han recibido % pedidos de este enlace en la última hora. '
                    'Si es correcto, llámanos y lo tramitamos.', v_recientes;
  end if;

  -- El precio lo pone el servidor, nunca el formulario: el cliente podría
  -- mandar el que quisiera.
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', l.sku,
           'cantidad', l.cantidad,
           'precio_unit', round(coalesce(pr.precio_venta, 0)
                                * (1 - v_descuento / 100), 2))), '[]'::jsonb)
    into v_lineas
    from jsonb_to_recordset(p_lineas) as l(sku text, cantidad numeric)
    join articulos a on a.sku = l.sku and a.clase = 'PAQUETE' and a.activo
    left join precios pr on pr.sku = l.sku
   where l.cantidad > 0 and l.cantidad = trunc(l.cantidad) and l.cantidad <= 999;

  if jsonb_array_length(v_lineas) = 0 then
    raise exception 'Ninguna de las líneas del pedido es válida.';
  end if;

  r := registrar_pedido_canal(
         p_operacion_id, v_ubicacion, v_lineas, 'Hostelería',
         'app', 'host-' || p_operacion_id::text, v_cliente,
         null, null, null, p_ocurrido_en,
         coalesce(nullif(btrim(p_nota), ''), 'Pedido por enlace'));

  return jsonb_build_object(
    'pedido_id', r ->> 'pedido_id',
    'numero', r ->> 'numero',
    'cliente', v_nombre,
    'idempotente', r -> 'idempotente');
end;
$$;

-- Estas funciones las llama el servidor con perfil SISTEMA; el enlace es la
-- credencial y se comprueba dentro. No se conceden a `anon`: el navegador del
-- cliente no habla con la base, habla con nuestro servidor.
grant execute on function
  generar_enlace_pedido(uuid), revocar_enlace_pedido(uuid),
  catalogo_pedido(text), crear_pedido_hosteleria(uuid, text, jsonb, text, timestamptz)
to authenticated;
