-- ═══════════════════════════════════════════════════════════════════════════
--  13 · PARÁMETROS DE ETIQUETA Y DE SINCRONIZACIÓN
-- ═══════════════════════════════════════════════════════════════════════════

insert into parametros (clave, valor, descripcion) values
  ('nombre_empresa', 'Mi Tostador',
   'Nombre comercial. Sale impreso en las etiquetas de El Corte Inglés'),
  ('texto_legal_etiqueta', '',
   'Línea pequeña opcional al pie de la etiqueta de venta propia'),
  ('loyverse_ultima_sincronizacion', '',
   'Fecha del último recibo traído de Loyverse. La gestiona sola la consulta periódica'),
  ('loyverse_dias_iniciales', '7',
   'Cuántos días hacia atrás mira la primera consulta a Loyverse')
on conflict (clave) do nothing;
