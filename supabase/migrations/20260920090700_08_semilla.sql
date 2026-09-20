-- ═══════════════════════════════════════════════════════════════════════════
--  08 · SEMILLA
--  Lo mínimo imprescindible para que la app arranque: las ubicaciones reales
--  del negocio y un administrador. Es idempotente: se puede volver a aplicar.
-- ═══════════════════════════════════════════════════════════════════════════

insert into ubicaciones (ubicacion_id, nombre, tipo, politica_lote, permite_venta, notas) values
  ('ALMACEN',  'Almacén y obrador', 'PROPIA',   'FIFO',        false,
   'Origen de todo. No se vende desde aquí: la salida hacia otro sitio es un traslado.'),
  ('TIENDA',   'Tienda física',     'PROPIA',   'LOTE_ACTIVO', true,
   'Ventas de Loyverse. El lote activo lo deja el escaneo de reposición.'),
  ('FURGONETA','Furgoneta de mercados', 'PROPIA','LOTE_ACTIVO', true,
   'Se carga antes de cada feria y se descarga al volver.'),
  ('ONLINE',   'Stock reservado a la web', 'PROPIA', 'LOTE_ACTIVO', true,
   'Lo que WooCommerce puede vender. Separarlo evita vender por web lo que va en la furgoneta.'),
  ('DEPOSITO_ECI', 'Depósito El Corte Inglés', 'DEPOSITO', 'FIFO', true,
   'Mercancía nuestra en sus tiendas. Servir aquí es un traslado, no una venta. '
   'Durante la prueba se lleva a mano: el informe de ventas se carga manualmente. '
   'FIFO por fuerza: sus tiendas mezclan lotes y reportan ventas agregadas.')
on conflict (ubicacion_id) do nothing;

-- Administrador inicial. El PIN 1234 hay que cambiarlo antes de usar la app
-- de verdad; la pantalla de ajustes avisa mientras siga puesto.
insert into usuarios (nombre, pin_hash, rol)
select 'Administrador', app.hash_pin('1234'), 'ADMIN'
 where not exists (select 1 from usuarios);
