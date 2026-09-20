-- ═══════════════════════════════════════════════════════════════════════════
--  CRITERIO: «Reserva de stock al confirmar pedido, descuento al servir.»
--
--  Es lo que impide que el mismo último paquete se venda por la web y en un
--  mercado el mismo sábado. Se comprueba que reservar NO saca nada del libro
--  pero sí lo hace invendible, y que servir sí lo saca.
-- ═══════════════════════════════════════════════════════════════════════════
set app.rol = 'ADMIN';

do $$
declare
  u        uuid := (select usuario_id from usuarios limit 1);
  lote     text := 'CAF-ETHYIR-250-260905-A';
  cant0    numeric; res0 numeric; disp0 numeric;
  cant1    numeric; res1 numeric; disp1 numeric;
  cant2    numeric; res2 numeric;
  movs0    bigint; movs1 bigint;
  r        jsonb;
  ped      uuid;
  fallos   int := 0;
begin
  select cantidad, reservado, disponible into cant0, res0, disp0
    from saldos where lote_id = lote and ubicacion_id = 'ONLINE';
  select count(*) into movs0 from movimientos;

  ---------------------------------------------------------------------------
  -- 1) Confirmar un pedido web RESERVA: compromete sin sacar del libro.
  ---------------------------------------------------------------------------
  r := registrar_pedido_canal(
         'aaaaaaaa-0000-4000-8000-000000000001', 'ONLINE',
         jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 3, 'precio_unit', 12.5)),
         'Online', 'woocommerce', 'woo-5001', null,
         '5001', 'woocommerce', 'Tarjeta',
         '2026-09-18T10:00:00+02'::timestamptz, 'Pedido web de prueba');
  ped := (r ->> 'pedido_id')::uuid;

  select cantidad, reservado, disponible into cant1, res1, disp1
    from saldos where lote_id = lote and ubicacion_id = 'ONLINE';
  select count(*) into movs1 from movimientos;

  if cant1 <> cant0 then
    raise warning 'FALLO: reservar cambió las existencias de % a %', cant0, cant1;
    fallos := fallos + 1;
  end if;
  if movs1 <> movs0 then
    raise warning 'FALLO: reservar escribió en el libro (% → % movimientos)', movs0, movs1;
    fallos := fallos + 1;
  end if;
  if res1 - res0 <> 3 then
    raise warning 'FALLO: reservado subió % en vez de 3', res1 - res0; fallos := fallos + 1;
  end if;
  if disp0 - disp1 <> 3 then
    raise warning 'FALLO: disponible bajó % en vez de 3', disp0 - disp1; fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 2) Lo reservado ya no se puede vender por otro canal. Es el punto de
  --    todo esto.
  ---------------------------------------------------------------------------
  begin
    perform registrar_venta(
      p_operacion_id => 'aaaaaaaa-0000-4000-8000-0000000000ff',
      p_ubicacion_id => 'ONLINE',
      p_lineas => jsonb_build_array(jsonb_build_object(
                    'sku', 'ETHYIR-250-GR', 'cantidad', disp1 + 1)),
      p_canal => 'Mostrador', p_usuario_id => u,
      p_ocurrido_en => '2026-09-18T10:05:00+02'::timestamptz);
    raise warning 'FALLO: se pudo vender más de lo disponible pese a la reserva';
    fallos := fallos + 1;
  exception when check_violation then
    null;   -- correcto: la reserva protege el stock comprometido
  end;

  ---------------------------------------------------------------------------
  -- 3) Confirmar dos veces el mismo pedido no reserva el doble.
  ---------------------------------------------------------------------------
  perform registrar_pedido_canal(
    'aaaaaaaa-0000-4000-8000-000000000001', 'ONLINE',
    jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 3, 'precio_unit', 12.5)),
    'Online', 'woocommerce', 'woo-5001', null, '5001', 'woocommerce', 'Tarjeta',
    '2026-09-18T10:00:00+02'::timestamptz, null);

  select reservado into res2 from saldos where lote_id = lote and ubicacion_id = 'ONLINE';
  if res2 <> res1 then
    raise warning 'FALLO: reconfirmar duplicó la reserva (% → %)', res1, res2;
    fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 4) Servir descuenta de verdad y suelta la reserva.
  ---------------------------------------------------------------------------
  perform servir_reservas_pedido(
    'aaaaaaaa-0000-4000-8000-000000000002', ped, u,
    '2026-09-19T09:00:00+02'::timestamptz, 'woocommerce', 'woo-5001:servido');

  select cantidad, reservado into cant2, res2
    from saldos where lote_id = lote and ubicacion_id = 'ONLINE';

  if cant1 - cant2 <> 3 then
    raise warning 'FALLO: servir descontó % en vez de 3', cant1 - cant2; fallos := fallos + 1;
  end if;
  if res2 <> res0 then
    raise warning 'FALLO: quedó reserva sin soltar (% en vez de %)', res2, res0;
    fallos := fallos + 1;
  end if;
  if (select estado from pedidos where pedido_id = ped) <> 'SERVIDO' then
    raise warning 'FALLO: el pedido no quedó como servido'; fallos := fallos + 1;
  end if;

  -- Servir dos veces no descuenta dos veces.
  perform servir_reservas_pedido(
    'aaaaaaaa-0000-4000-8000-000000000002', ped, u,
    '2026-09-19T09:00:00+02'::timestamptz, 'woocommerce', 'woo-5001:servido');
  if (select cantidad from saldos where lote_id = lote and ubicacion_id = 'ONLINE') <> cant2 then
    raise warning 'FALLO: servir de nuevo volvió a descontar'; fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 5) Un pedido cancelado ANTES de servirse suelta lo reservado, y el
  --    stock vuelve a estar disponible para quien sea.
  ---------------------------------------------------------------------------
  r := registrar_pedido_canal(
         'aaaaaaaa-0000-4000-8000-000000000003', 'ONLINE',
         jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 2, 'precio_unit', 12.5)),
         'Online', 'woocommerce', 'woo-5002', null, '5002', 'woocommerce', 'Tarjeta',
         '2026-09-19T11:00:00+02'::timestamptz, null);

  perform liberar_reservas_pedido('aaaaaaaa-0000-4000-8000-000000000004',
            (r ->> 'pedido_id')::uuid, u, '2026-09-19T12:00:00+02'::timestamptz);

  if (select reservado from saldos where lote_id = lote and ubicacion_id = 'ONLINE') <> res0 then
    raise warning 'FALLO: cancelar no soltó la reserva'; fallos := fallos + 1;
  end if;
  if (select cantidad from saldos where lote_id = lote and ubicacion_id = 'ONLINE') <> cant2 then
    raise warning 'FALLO: cancelar tocó las existencias, y no debía'; fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 6) Un pedido cancelado DESPUÉS de servirse devuelve el café a su lote.
  ---------------------------------------------------------------------------
  perform registrar_devolucion(
    'aaaaaaaa-0000-4000-8000-000000000005', 'ONLINE',
    jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 3)),
    'woo-5001:servido', 'woocommerce', 'woo-5001:devuelto', u,
    '2026-09-20T10:00:00+02'::timestamptz, 'Pedido web cancelado tras enviarse');

  if (select cantidad from saldos where lote_id = lote and ubicacion_id = 'ONLINE') <> cant1 then
    raise warning 'FALLO: la devolución no dejó el stock como antes de servir (% vs %)',
      (select cantidad from saldos where lote_id = lote and ubicacion_id = 'ONLINE'), cant1;
    fallos := fallos + 1;
  end if;

  if fallos > 0 then
    raise exception 'PEDIDOS DE CANAL: % comprobaciones fallidas', fallos;
  end if;

  raise notice 'PEDIDOS DE CANAL ✓  reservar compromete sin tocar el libro, servir descuenta, cancelar devuelve';
end $$;
