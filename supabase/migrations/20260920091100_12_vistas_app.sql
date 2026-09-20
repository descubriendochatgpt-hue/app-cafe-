-- ═══════════════════════════════════════════════════════════════════════════
--  12 · VISTAS PARA LA APP
--  Lo que la PWA necesita llevarse al móvil para poder trabajar sin cobertura.
-- ═══════════════════════════════════════════════════════════════════════════

/* Ficha completa de un lote: es lo que se resuelve al escanear un QR.
   Se cachea entera en el móvil, así que un escaneo sin red sigue diciendo
   qué café es, cuándo se tostó y cuántos días lleva. */
create view v_lote_detalle as
  select l.lote_id,
         l.sku,
         a.clase,
         a.unidad,
         a.ean13,
         a.cafe_id,
         c.nombre            as cafe,
         c.origen,
         c.perfil_tueste,
         f.formato_id,
         f.nombre            as formato,
         f.gramos,
         f.molienda,
         l.fecha_tostado,
         l.fecha_consumo_preferente,
         l.fecha_recepcion,
         l.proveedor,
         case when l.fecha_tostado is null then null
              else current_date - l.fecha_tostado end as dias_desde_tueste,
         case
           when l.fecha_tostado is null then 'SIN_FECHA'
           when current_date - l.fecha_tostado >= app.parametro_int('dias_frescura_critico', 90)
             then 'CRITICO'
           when current_date - l.fecha_tostado >= app.parametro_int('dias_frescura_aviso', 45)
             then 'AVISO'
           else 'FRESCO'
         end as frescura,
         coalesce((select sum(s.cantidad) from saldos s where s.lote_id = l.lote_id), 0)
           as stock_total
    from lotes l
    join articulos a on a.sku = l.sku
    join cafes c     on c.cafe_id = a.cafe_id
    left join formatos f on f.formato_id = a.formato_id;

/* Saldo por lote y ubicación, con el nombre legible. La PWA la usa para
   decir «quedan 7 en la furgoneta» sin tener que cruzar nada. */
create view v_saldo_detalle as
  select s.lote_id, s.sku, s.ubicacion_id,
         u.nombre as ubicacion, u.tipo as tipo_ubicacion,
         s.cantidad, s.reservado, s.disponible,
         (la.lote_id is not null) as es_lote_activo
    from saldos s
    join ubicaciones u on u.ubicacion_id = s.ubicacion_id
    left join lote_activo la
      on la.ubicacion_id = s.ubicacion_id
     and la.sku = s.sku
     and la.lote_id = s.lote_id
   where s.cantidad <> 0;

grant select on v_lote_detalle, v_saldo_detalle to authenticated;
