-- ═══════════════════════════════════════════════════════════════════════════
--  22 · PANEL
--
--  Cómo va el negocio, en una consulta. Todo se deriva del libro y de los
--  pedidos; no hay ninguna cifra almacenada que pueda quedarse vieja.
--
--  Los importes solo salen para quien puede verlos. Esta función es SECURITY
--  DEFINER —necesita leer tablas que un operario no lee—, así que la
--  comprobación de perfil la hace ella misma en lugar de delegarla en RLS.
--  Es la excepción, y por eso va escrita aquí de forma explícita.
-- ═══════════════════════════════════════════════════════════════════════════

insert into parametros (clave, valor, descripcion) values
  ('dias_cliente_dormido', '60',
   'Dias sin pedir tras los que un cliente cuenta como dormido en el panel')
on conflict (clave) do nothing;


create or replace function panel(p_dias integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_desde     date;
  v_anterior  date;
  v_dinero    boolean;
  v_ventas    jsonb;
  v_por_dia   jsonb;
  v_por_canal jsonb;
  v_top       jsonb;
  v_prod      jsonb;
  v_stock     jsonb;
  v_clientes  jsonb;
  v_avisos    jsonb;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse.' using errcode = 'insufficient_privilege';
  end if;

  v_dinero := app.tiene_nivel('GESTOR');
  p_dias := greatest(1, least(coalesce(p_dias, 30), 730));
  v_desde := current_date - p_dias;
  v_anterior := v_desde - p_dias;

  -- El periodo se cierra HOY, arriba y abajo. Hay pedidos con fecha futura
  -- —un albarán de El Corte Inglés se firma con la fecha de entrega—, y si el
  -- total los contara mientras la serie por día se para en hoy, el gráfico y
  -- la cifra de encima dirían cosas distintas. Además, «lo vendido en 30
  -- días» no puede incluir lo que todavía no ha pasado.

  /* ── Ventas ──
     Se cuentan los pedidos ya servidos o entregados: un pedido confirmado
     todavía puede caerse, y contarlo como venta infla la cifra. */
  with servidos as (
    select p.pedido_id, p.fecha, p.canal, p.total, p.base, p.cliente_id
      from pedidos p
     where p.estado in ('SERVIDO', 'ENTREGADO')
       and p.fecha between v_desde and current_date
  ),
  lineas as (
    select pl.sku, pl.servidas, pl.importe, pl.precio_unit,
           coalesce(pr.coste_unitario, 0) as coste
      from pedido_lineas pl
      join servidos s on s.pedido_id = pl.pedido_id
      left join precios pr on pr.sku = pl.sku
  )
  select jsonb_build_object(
           'pedidos', (select count(*) from servidos),
           'unidades', (select coalesce(sum(servidas), 0) from lineas),
           'total', case when v_dinero
                      then (select coalesce(sum(total), 0) from servidos) end,
           'coste', case when v_dinero
                      then (select coalesce(sum(servidas * coste), 0) from lineas) end,
           'margen', case when v_dinero then (
                       select coalesce(sum(importe), 0) - coalesce(sum(servidas * coste), 0)
                         from lineas) end,
           -- Sin costes puestos el margen no significa nada, y más vale no
           -- enseñar un número que parece bueno porque falta la mitad.
           'costes_completos', (select count(*) = 0 from lineas where coste = 0),
           'anterior', case when v_dinero then (
                         select coalesce(sum(p.total), 0) from pedidos p
                          where p.estado in ('SERVIDO','ENTREGADO')
                            and p.fecha >= v_anterior and p.fecha < v_desde) end)
    into v_ventas;

  /* ── Por día, para ver la forma del periodo ── */
  select coalesce(jsonb_agg(jsonb_build_object(
           'fecha', d.dia::date, 'pedidos', coalesce(x.n, 0),
           'unidades', coalesce(x.uds, 0),
           'total', case when v_dinero then coalesce(x.total, 0) end) order by d.dia), '[]'::jsonb)
    into v_por_dia
    -- ::date, no `d.dia` a secas. generate_series sobre fechas devuelve
    -- TIMESTAMP, y sin el corte la serie sale como «2026-08-21T00:00:00+00:00»
    -- en vez de «2026-08-21». Quien la lee se encuentra una fecha con hora
    -- donde esperaba un día.
    from generate_series(v_desde, current_date, interval '1 day') as d(dia)
    left join (
      -- Agrupado por fecha y solo por fecha. Agrupar además por pedido daría
      -- una fila por pedido, y el día con tres pedidos saldría tres veces en
      -- la serie: tres barras para el mismo día.
      select p.fecha,
             count(*) as n,
             sum(p.total) as total,
             sum((select coalesce(sum(pl.servidas), 0) from pedido_lineas pl
                   where pl.pedido_id = p.pedido_id)) as uds
        from pedidos p
       where p.estado in ('SERVIDO','ENTREGADO') and p.fecha between v_desde and current_date
       group by p.fecha
    ) x on x.fecha = d.dia::date;

  /* ── Por canal ── */
  select coalesce(jsonb_agg(jsonb_build_object(
           'canal', canal, 'pedidos', n,
           'total', case when v_dinero then total end) order by n desc), '[]'::jsonb)
    into v_por_canal
    from (select p.canal, count(*) as n, sum(p.total) as total
            from pedidos p
           where p.estado in ('SERVIDO','ENTREGADO') and p.fecha between v_desde and current_date
           group by p.canal) z;

  /* ── Lo que más se vende ── */
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', sku, 'unidades', uds,
           'importe', case when v_dinero then importe end) order by uds desc), '[]'::jsonb)
    into v_top
    from (select pl.sku, sum(pl.servidas) as uds, sum(pl.importe) as importe
            from pedido_lineas pl
            join pedidos p on p.pedido_id = pl.pedido_id
           where p.estado in ('SERVIDO','ENTREGADO') and p.fecha between v_desde and current_date
           group by pl.sku
           having sum(pl.servidas) > 0
           order by 2 desc limit 8) z;

  /* ── Producción ── */
  select jsonb_build_object(
           'tuestes', count(*),
           'kg_verde', coalesce(sum((datos ->> 'kg_verde')::numeric), 0),
           'kg_tostado', coalesce(sum((datos ->> 'kg_tostado')::numeric), 0),
           'merma_media', round(avg((datos ->> 'merma_pct')::numeric), 1))
    into v_prod
    from operaciones
   where tipo = 'TUESTE' and ocurrido_en >= v_desde
     and ocurrido_en < current_date + 1
     and datos ? 'kg_verde';

  /* ── Stock ── */
  select jsonb_build_object(
           'unidades', coalesce(sum(s.cantidad) filter (where a.unidad = 'UD'), 0),
           'kg_verde', coalesce(sum(s.cantidad) filter (where a.unidad = 'KG'), 0),
           'valor', case when v_dinero then
             coalesce(sum(s.cantidad * coalesce(pr.coste_unitario, 0)), 0) end,
           'referencias', count(distinct s.sku))
    into v_stock
    from saldos s
    join articulos a on a.sku = s.sku
    left join precios pr on pr.sku = s.sku
   where s.cantidad > 0;

  /* ── Clientes ── */
  select jsonb_build_object(
           'nuevos', (select count(*) from clientes
                       where alta is not null and alta >= v_desde),
           'dormidos', (
             select count(*) from clientes c
              where c.activo
                and exists (select 1 from pedidos p where p.cliente_id = c.cliente_id)
                and not exists (
                  select 1 from pedidos p
                   where p.cliente_id = c.cliente_id
                     and p.fecha >= current_date - app.parametro_int('dias_cliente_dormido', 60))))
    into v_clientes;

  /* ── Lo que hay que mirar ── */
  select jsonb_build_object(
           'bajo_minimo', case when v_dinero then (
             select count(*) from (
               select pr.sku from precios pr
                where pr.stock_minimo is not null
                  and coalesce((select sum(s.cantidad) from saldos s where s.sku = pr.sku), 0)
                      <= pr.stock_minimo) z) end,
           'envejeciendo', (select count(*) from v_frescura where frescura <> 'FRESCO'),
           'incidencias', (select count(*) from incidencias where estado = 'ABIERTA'),
           'pedidos_pendientes', (select count(*) from pedidos
                                   where estado in ('CONFIRMADO','PREPARANDO')),
           'deposito_viejo', (select count(*) from v_deposito where envejecido))
    into v_avisos;

  return jsonb_build_object(
    'dias', p_dias, 'desde', v_desde, 'con_importes', v_dinero,
    'ventas', v_ventas, 'por_dia', v_por_dia, 'por_canal', v_por_canal,
    'top', v_top, 'produccion', v_prod, 'stock', v_stock,
    'clientes', v_clientes, 'avisos', v_avisos);
end;
$$;

grant execute on function panel(integer) to authenticated;
