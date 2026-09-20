-- Una historia de operaciones parecida a una semana real: se reciben dos
-- sacos, se tuesta, se repone la tienda y la furgoneta, se sirve a ECI y se
-- vende por varios canales.
set app.rol = 'ADMIN';

do $$
declare
  u uuid := (select usuario_id from usuarios order by creado_en limit 1);
  r jsonb;
  lote_eth text;
  lote_col text;
  paq_eth  text;
  paq_col  text;
begin
  -- Dos sacos de verde, con una semana de diferencia.
  r := registrar_recepcion_verde(
         '11111111-1111-4111-8111-000000000001', 'VRD-ETHYIR', 60,
         'ALMACEN', 'Importador Sur', '2026-09-01', 8.20, u,
         '2026-09-01T09:00:00+02'::timestamptz);
  lote_eth := r ->> 'lote_id';

  r := registrar_recepcion_verde(
         '11111111-1111-4111-8111-000000000002', 'VRD-COLHUI', 45,
         'ALMACEN', 'Importador Sur', '2026-09-03', 7.40, u,
         '2026-09-03T09:00:00+02'::timestamptz);
  lote_col := r ->> 'lote_id';

  -- Tueste 1: 20 kg de verde → 65 paquetes de 250 g (merma ~18,75 %).
  r := registrar_tueste(
         '22222222-2222-4222-8222-000000000001',
         jsonb_build_array(jsonb_build_object('lote_id', lote_eth, 'cantidad', 20)),
         jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 65)),
         'ALMACEN', u, '2026-09-05T08:30:00+02'::timestamptz);
  paq_eth := r -> 'lotes' -> 0 ->> 'lote_id';
  raise notice 'Tueste Etiopía: % · merma %%%', paq_eth, r ->> 'merma_pct';

  -- Tueste 2: Colombia.
  r := registrar_tueste(
         '22222222-2222-4222-8222-000000000002',
         jsonb_build_array(jsonb_build_object('lote_id', lote_col, 'cantidad', 15)),
         jsonb_build_array(jsonb_build_object('sku', 'COLHUI-250-GR', 'cantidad', 49)),
         'ALMACEN', u, '2026-09-06T08:30:00+02'::timestamptz);
  paq_col := r -> 'lotes' -> 0 ->> 'lote_id';

  -- Reposiciones. Cada traslado deja puesto el lote activo en el destino:
  -- es el gesto que después usan las ventas por webhook.
  perform registrar_traslado('33333333-3333-4333-8333-000000000001',
            paq_eth, 'ALMACEN', 'TIENDA', 20, u, '2026-09-07T10:00:00+02'::timestamptz);
  perform registrar_traslado('33333333-3333-4333-8333-000000000002',
            paq_col, 'ALMACEN', 'TIENDA', 15, u, '2026-09-07T10:05:00+02'::timestamptz);
  perform registrar_traslado('33333333-3333-4333-8333-000000000003',
            paq_eth, 'ALMACEN', 'FURGONETA', 12, u, '2026-09-12T07:00:00+02'::timestamptz);
  perform registrar_traslado('33333333-3333-4333-8333-000000000004',
            paq_eth, 'ALMACEN', 'ONLINE', 10, u, '2026-09-08T09:00:00+02'::timestamptz);

  -- Servir a El Corte Inglés es un TRASLADO: la mercancía sigue siendo nuestra.
  perform registrar_traslado('33333333-3333-4333-8333-000000000005',
            paq_eth, 'ALMACEN', 'DEPOSITO_ECI', 18, u, '2026-09-09T11:00:00+02'::timestamptz);

  -- Venta de tienda que llega por webhook de Loyverse: sin lote, se deduce.
  perform registrar_venta(
    p_operacion_id => '44444444-4444-4444-8444-000000000001',
    p_ubicacion_id => 'TIENDA',
    p_lineas => jsonb_build_array(
                  jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 3, 'precio_unit', 12.50),
                  jsonb_build_object('sku', 'COLHUI-250-GR', 'cantidad', 2, 'precio_unit', 11.00)),
    p_canal => 'Mostrador', p_origen => 'loyverse', p_origen_id => 'receipt-8891',
    p_documento_fiscal => 'LV-2026-8891', p_documento_fiscal_sistema => 'loyverse',
    p_usuario_id => u, p_ocurrido_en => '2026-09-14T18:20:00+02'::timestamptz);

  -- Venta de mercado con la bolsa escaneada: el lote viene dado.
  perform registrar_venta(
    p_operacion_id => '44444444-4444-4444-8444-000000000002',
    p_ubicacion_id => 'FURGONETA',
    p_lineas => jsonb_build_array(
                  jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 4,
                                     'lote_id', paq_eth, 'precio_unit', 13.00)),
    p_canal => 'Mercado', p_forma_pago => 'Efectivo',
    p_usuario_id => u, p_ocurrido_en => '2026-09-15T12:00:00+02'::timestamptz);

  -- Venta web.
  perform registrar_venta(
    p_operacion_id => '44444444-4444-4444-8444-000000000003',
    p_ubicacion_id => 'ONLINE',
    p_lineas => jsonb_build_array(
                  jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 2, 'precio_unit', 12.50)),
    p_canal => 'Online', p_origen => 'woocommerce', p_origen_id => 'order-5512',
    p_documento_fiscal => 'WC-2026-5512', p_documento_fiscal_sistema => 'woocommerce',
    p_usuario_id => u, p_ocurrido_en => '2026-09-16T09:10:00+02'::timestamptz);

  -- Una rotura y un recuento que no cuadra.
  perform registrar_movimiento('55555555-5555-4555-8555-000000000001', 'MERMA',
            paq_eth, 'TIENDA', 1, u, '2026-09-17T16:00:00+02'::timestamptz,
            'Bolsa rota al reponer');

  perform registrar_ajuste_inventario('66666666-6666-4666-8666-000000000001',
            'FURGONETA',
            jsonb_build_array(jsonb_build_object('lote_id', paq_eth, 'contado', 7)),
            u, '2026-09-18T20:00:00+02'::timestamptz, 'Recuento al volver de la feria');
end $$;
