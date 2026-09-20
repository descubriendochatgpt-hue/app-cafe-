-- Catálogo de pruebas: los maestros, que no son hechos contables.
-- Se carga igual en la base original y en la de reproducción.
set app.rol = 'ADMIN';

insert into cafes (cafe_id, nombre, origen, perfil_tueste) values
  ('ETHYIR', 'Etiopía Yirgacheffe', 'Etiopía',  'Claro'),
  ('COLHUI', 'Colombia Huila',      'Colombia', 'Medio')
on conflict do nothing;

insert into formatos (formato_id, nombre, gramos, molienda) values
  ('F250G', '250 g grano',  250, 'GRANO'),
  ('F250M', '250 g molido', 250, 'MOLIDO'),
  ('F1KG',  '1 kg grano',  1000, 'GRANO')
on conflict do nothing;

insert into articulos (sku, clase, cafe_id, formato_id, unidad, ean13) values
  ('VRD-ETHYIR',    'VERDE',   'ETHYIR', null,    'KG', null),
  ('VRD-COLHUI',    'VERDE',   'COLHUI', null,    'KG', null),
  ('ETHYIR-250-GR', 'PAQUETE', 'ETHYIR', 'F250G', 'UD', '8412345000010'),
  ('ETHYIR-1K-GR',  'PAQUETE', 'ETHYIR', 'F1KG',  'UD', null),
  ('COLHUI-250-GR', 'PAQUETE', 'COLHUI', 'F250G', 'UD', null)
on conflict do nothing;

insert into precios (sku, precio_venta, coste_unitario, stock_minimo) values
  ('ETHYIR-250-GR', 12.50, 6.20, 12),
  ('ETHYIR-1K-GR',  42.00, 21.00, 4),
  ('COLHUI-250-GR', 11.00, 5.40, 12)
on conflict do nothing;

insert into mapeo_articulos (canal, codigo_externo, sku, descripcion_externa) values
  ('loyverse', 'LV-1001', 'ETHYIR-250-GR', 'Yirgacheffe 250g'),
  ('loyverse', 'LV-1002', 'COLHUI-250-GR', 'Huila 250g')
on conflict do nothing;

-- Un cliente de hostelería, para el flujo de pedidos por enlace.
insert into clientes (cliente_id, nombre, tipo, nif, email, descuento_pct) values
  ('cccccccc-0000-4000-8000-000000000001', 'Cafetería La Plaza', 'Hostelería',
   'B33000000', 'pedidos@laplaza.es', 10)
on conflict do nothing;
