-- ═══════════════════════════════════════════════════════════════════════════
--  23 · AVISO DIARIO POR CORREO
--
--  Un correo al día con lo de ayer y con lo que hay que mirar hoy. Es la
--  única pieza del sistema que sale a buscar a la persona en vez de esperar
--  a que abra la aplicación, y por eso hay que tratarla con cuidado.
--
--  DOS DECISIONES QUE VIENEN DE LA EXPERIENCIA CON ESTOS CORREOS
--
--  1) Se envía UNA VEZ AL DÍA, y eso se garantiza aquí, no en el servidor.
--     Vercel puede disparar un cron dos veces, un despliegue puede solaparse
--     con otro, y un reintento tras un fallo de red es normal. La fecha es
--     clave primaria: el segundo intento del mismo día no manda nada.
--
--  2) El correo lleva DETALLE, no solo cuentas. «3 referencias bajo mínimos»
--     obliga a abrir la aplicación para saber cuáles; con los nombres dentro,
--     se decide desde el propio correo mientras se desayuna. Un aviso que
--     obliga a ir a otro sitio para entenderlo acaba sin leerse.
-- ═══════════════════════════════════════════════════════════════════════════

create table avisos_enviados (
  fecha          date primary key,
  enviado_en     timestamptz not null default now(),
  destinatarios  text[] not null,
  resumen        jsonb not null
);

comment on table avisos_enviados is
  'Un correo por día, y la prueba de que se mandó. La clave primaria por '
  'fecha es lo que impide que un cron disparado dos veces envíe dos correos.';

alter table avisos_enviados enable row level security;
alter table avisos_enviados force row level security;
revoke all on avisos_enviados from anon, authenticated;

insert into parametros (clave, valor, descripcion) values
  ('avisos_solo_si_hay', 'no',
   'Con «si», el correo diario solo sale si hay algo que mirar. Con «no», '
   'sale siempre con el resumen de ventas'),
  ('avisos_hora', '7',
   'Hora aproximada a la que se espera el correo. Solo informativa: el '
   'horario de verdad está en vercel.json')
on conflict (clave) do nothing;


/**
 * Lo que va dentro del correo de un día. Con nombres, no solo con cuentas.
 *
 * Es SECURITY DEFINER y lleva importes, así que comprueba el perfil ella
 * misma: lo llama la tarea programada con perfil SISTEMA.
 */
create or replace function resumen_diario(p_fecha date default current_date - 1)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_ventas     jsonb;
  v_canales    jsonb;
  v_produccion jsonb;
  v_minimos    jsonb;
  v_frescura   jsonb;
  v_incid      jsonb;
  v_pendientes jsonb;
  v_deposito   jsonb;
  v_descuadres integer;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'El resumen diario lleva importes.'
      using errcode = 'insufficient_privilege';
  end if;

  /* ── Lo que se vendió ayer ── */
  select jsonb_build_object(
           'pedidos', count(*),
           'total', coalesce(sum(p.total), 0),
           'unidades', coalesce((
             select sum(pl.servidas) from pedido_lineas pl
              join pedidos q on q.pedido_id = pl.pedido_id
              where q.estado in ('SERVIDO','ENTREGADO') and q.fecha = p_fecha), 0))
    into v_ventas
    from pedidos p
   where p.estado in ('SERVIDO','ENTREGADO') and p.fecha = p_fecha;

  select coalesce(jsonb_agg(jsonb_build_object(
           'canal', canal, 'pedidos', n, 'total', total) order by total desc), '[]'::jsonb)
    into v_canales
    from (select p.canal, count(*) as n, sum(p.total) as total
            from pedidos p
           where p.estado in ('SERVIDO','ENTREGADO') and p.fecha = p_fecha
           group by p.canal) z;

  select jsonb_build_object(
           'tuestes', count(*),
           'kg_verde', coalesce(sum((datos ->> 'kg_verde')::numeric), 0),
           'kg_tostado', coalesce(sum((datos ->> 'kg_tostado')::numeric), 0))
    into v_produccion
    from operaciones
   where tipo = 'TUESTE' and datos ? 'kg_verde'
     and ocurrido_en >= p_fecha and ocurrido_en < p_fecha + 1;

  /* ── Lo que hay que mirar, CON NOMBRES ── */
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', sku, 'quedan', quedan, 'minimo', minimo) order by quedan), '[]'::jsonb)
    into v_minimos
    from (
      select pr.sku,
             coalesce((select sum(s.cantidad) from saldos s where s.sku = pr.sku), 0) as quedan,
             pr.stock_minimo as minimo
        from precios pr
       where pr.stock_minimo is not null
         and coalesce((select sum(s.cantidad) from saldos s where s.sku = pr.sku), 0)
             <= pr.stock_minimo) z;

  select coalesce(jsonb_agg(jsonb_build_object(
           'lote', lote_id, 'sku', sku, 'ubicacion', ubicacion_id,
           'cantidad', cantidad, 'dias', dias_desde_tueste, 'estado', frescura)
           order by dias_desde_tueste desc), '[]'::jsonb)
    into v_frescura
    from v_frescura
   where frescura <> 'FRESCO';

  select coalesce(jsonb_agg(jsonb_build_object(
           'tipo', tipo, 'canal', canal, 'referencia', referencia,
           'desde', creado_en::date) order by creado_en), '[]'::jsonb)
    into v_incid
    from incidencias where estado = 'ABIERTA';

  -- Con el nombre del cliente, no con su identificador: el correo se lee en
  -- el móvil y «Bar Nuria» dice algo que un UUID no dice.
  select coalesce(jsonb_agg(jsonb_build_object(
           'pedido', p.numero, 'canal', p.canal,
           'cliente', coalesce(c.nombre, 'sin cliente'),
           'estado', p.estado, 'desde', p.fecha) order by p.fecha), '[]'::jsonb)
    into v_pendientes
    from pedidos p
    left join clientes c on c.cliente_id = p.cliente_id
   where p.estado in ('CONFIRMADO','PREPARANDO');

  select coalesce(jsonb_agg(jsonb_build_object(
           'ubicacion', ubicacion_id, 'sku', sku, 'saldo', saldo,
           'dias', dias_en_deposito) order by dias_en_deposito desc), '[]'::jsonb)
    into v_deposito
    from v_deposito where envejecido;

  -- Un descuadre entre el libro y la proyección no debería existir nunca. Si
  -- alguna vez existe, es lo primero que hay que leer del correo.
  select count(*) into v_descuadres from app.verificar_saldos();

  return jsonb_build_object(
    'fecha', p_fecha,
    'ventas', v_ventas,
    'canales', v_canales,
    'produccion', v_produccion,
    'minimos', v_minimos,
    'frescura', v_frescura,
    'incidencias', v_incid,
    'pendientes', v_pendientes,
    'deposito', v_deposito,
    'descuadres', v_descuadres,
    -- El ajuste viaja con el resumen en vez de consultarse aparte: PostgREST
    -- no publica el esquema `app`, y una segunda llamada para leer un
    -- parámetro es una ida y vuelta de más en algo que ya lo sabe.
    'solo_si_hay', lower(app.parametro('avisos_solo_si_hay', 'no')) = 'si',
    'hay_avisos', (
      jsonb_array_length(v_minimos) + jsonb_array_length(v_frescura)
      + jsonb_array_length(v_incid) + jsonb_array_length(v_deposito)
      + v_descuadres) > 0);
end;
$$;


/**
 * Reserva el envío del día. Devuelve false si ya se mandó.
 *
 * Se llama ANTES de mandar, no después: si se apuntara después, dos crones
 * a la vez pasarían los dos por la comprobación y saldrían dos correos. El
 * precio de hacerlo así es que un fallo del proveedor deja el día marcado
 * sin correo; por eso `soltar_aviso_diario` lo deshace.
 */
create or replace function reservar_aviso_diario(
  p_fecha date, p_destinatarios text[], p_resumen jsonb
) returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Solo el sistema envía los avisos.'
      using errcode = 'insufficient_privilege';
  end if;

  insert into avisos_enviados (fecha, destinatarios, resumen)
  values (p_fecha, p_destinatarios, p_resumen)
  on conflict (fecha) do nothing;

  return found;
end;
$$;

create or replace function soltar_aviso_diario(p_fecha date)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Solo el sistema envía los avisos.'
      using errcode = 'insufficient_privilege';
  end if;
  delete from avisos_enviados where fecha = p_fecha;
  return found;
end;
$$;

grant execute on function
  resumen_diario(date),
  reservar_aviso_diario(date, text[], jsonb),
  soltar_aviso_diario(date)
to authenticated;
