-- ═══════════════════════════════════════════════════════════════════════════
--  10 · VISTAS DE CONSULTA
--  Todo se deriva del libro. Ninguna de estas vistas guarda nada.
-- ═══════════════════════════════════════════════════════════════════════════

/* Stock consolidado por artículo y ubicación. */
create view v_stock as
  select s.sku,
         a.cafe_id,
         c.nombre       as cafe,
         f.nombre       as formato,
         a.unidad,
         s.ubicacion_id,
         u.nombre       as ubicacion,
         u.tipo         as tipo_ubicacion,
         sum(s.cantidad)   as cantidad,
         sum(s.reservado)  as reservado,
         sum(s.disponible) as disponible,
         count(*)          as lotes
    from saldos s
    join articulos a  on a.sku = s.sku
    join cafes c      on c.cafe_id = a.cafe_id
    left join formatos f on f.formato_id = a.formato_id
    join ubicaciones u on u.ubicacion_id = s.ubicacion_id
   group by s.sku, a.cafe_id, c.nombre, f.nombre, a.unidad,
            s.ubicacion_id, u.nombre, u.tipo;

/* Frescura: cuántos días lleva cada lote desde el tueste. Los umbrales salen
   de parámetros, no del código, para poder ajustarlos al perfil de la casa. */
create view v_frescura as
  select s.lote_id, s.sku, s.ubicacion_id, s.cantidad,
         l.fecha_tostado,
         l.fecha_consumo_preferente,
         (current_date - l.fecha_tostado) as dias_desde_tueste,
         case
           when l.fecha_tostado is null then 'SIN_FECHA'
           when current_date - l.fecha_tostado >= app.parametro_int('dias_frescura_critico', 90)
             then 'CRITICO'
           when current_date - l.fecha_tostado >= app.parametro_int('dias_frescura_aviso', 45)
             then 'AVISO'
           else 'FRESCO'
         end as frescura
    from saldos s
    join lotes l on l.lote_id = s.lote_id
   where s.cantidad > 0 and l.fecha_tostado is not null;

/* ── Depósito ──
   El criterio de aceptación del régimen de depósito, expresado como consulta:
   lo que queda tiene que ser lo servido, menos lo reportado como vendido,
   menos lo devuelto. Las tres cifras salen del mismo libro, así que no pueden
   discrepar del saldo: si lo hicieran, el descuadre sería visible aquí.

   Vale para cualquier ubicación de tipo DEPOSITO. Durante la prueba con El
   Corte Inglés los tres apuntes se cargan a mano; el día que haya integración
   los escribirá el conector y esta vista no cambia. */
create view v_deposito as
  with apuntes as (
    select m.ubicacion_id,
           m.sku,
           m.lote_id,
           sum(m.cantidad) filter (where o.tipo = 'TRASLADO'   and m.cantidad > 0) as servido,
           sum(m.cantidad) filter (where o.tipo = 'TRASLADO'   and m.cantidad < 0) as devuelto,
           sum(m.cantidad) filter (where o.tipo = 'VENTA')                          as vendido,
           sum(m.cantidad) filter (where o.tipo not in ('TRASLADO','VENTA'))        as otros,
           min(m.ocurrido_en) filter (where o.tipo = 'TRASLADO' and m.cantidad > 0) as primera_entrega
      from movimientos m
      join operaciones o  on o.operacion_id = m.operacion_id
      join ubicaciones ub on ub.ubicacion_id = m.ubicacion_id
     where ub.tipo = 'DEPOSITO'
     group by m.ubicacion_id, m.sku, m.lote_id
  )
  select ap.ubicacion_id,
         ap.sku,
         ap.lote_id,
         coalesce(ap.servido, 0)        as servido,
         -coalesce(ap.vendido, 0)       as vendido,
         -coalesce(ap.devuelto, 0)      as devuelto,
         coalesce(ap.otros, 0)          as otros_ajustes,
         coalesce(s.cantidad, 0)        as saldo,
         -- Debe ser siempre cero. Si no lo es, hay un descuadre que mirar.
         coalesce(s.cantidad, 0)
           - (coalesce(ap.servido, 0) + coalesce(ap.vendido, 0)
              + coalesce(ap.devuelto, 0) + coalesce(ap.otros, 0)) as descuadre,
         ap.primera_entrega,
         (current_date - ap.primera_entrega::date) as dias_en_deposito,
         (current_date - ap.primera_entrega::date)
           >= app.parametro_int('dias_antiguedad_deposito', 90) as envejecido
    from apuntes ap
    left join saldos s
      on s.lote_id = ap.lote_id and s.ubicacion_id = ap.ubicacion_id;

comment on view v_deposito is
  'Servido − vendido − devuelto = saldo, para cada lote en depósito. '
  'La columna `descuadre` tiene que ser cero siempre. Incluye la antigüedad '
  'para saber qué lleva demasiado tiempo fuera.';

/* Trazabilidad: de un lote de venta hacia atrás, hasta los sacos de origen. */
create view v_trazabilidad as
  with recursive arbol as (
    select l.lote_id as lote, l.lote_id as ancestro, 0 as nivel, l.sku, l.fecha_tostado
      from lotes l
    union all
    select a.lote, lc.lote_padre_id, a.nivel + 1, a.sku, a.fecha_tostado
      from arbol a
      join lote_composicion lc on lc.lote_hijo_id = a.ancestro
  )
  select ar.lote,
         ar.nivel,
         ar.ancestro           as lote_origen,
         lo.sku                as sku_origen,
         lo.proveedor,
         lo.fecha_recepcion
    from arbol ar
    join lotes lo on lo.lote_id = ar.ancestro
   where ar.nivel > 0;

grant select on v_stock, v_frescura, v_deposito, v_trazabilidad to authenticated;
