-- ═══════════════════════════════════════════════════════════════════════════
--  BULTOS · preparar y empaquetar son cosas distintas.
--
--  Preparar saca el café del estante y SÍ toca el inventario. Empaquetar lo
--  mete en cajas y NO lo toca: si lo hiciera, la salida se contaría dos veces.
--  Eso es lo principal que se comprueba aquí.
-- ═══════════════════════════════════════════════════════════════════════════
set app.rol = 'ADMIN';

do $$
declare
  u        uuid := (select usuario_id from usuarios limit 1);
  lote     text := 'CAF-ETHYIR-250-260905-A';
  otro     text := 'CAF-COLHUI-250-260906-A';
  ped      uuid;
  r        jsonb;
  bulto    uuid;
  cant0    numeric; res0 numeric;
  cant1    numeric; res1 numeric;
  movs0    bigint;
  errores  int := 0;
begin
  -- Pedido web de 3 paquetes, con su stock reservado.
  r := registrar_pedido_canal(
         'bbbbbbbb-0000-4000-8000-000000000001', 'ONLINE',
         jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 3, 'precio_unit', 12.5)),
         'Online', 'woocommerce', 'woo-7001', null, '7001', 'woocommerce', 'Tarjeta',
         '2026-09-19T09:00:00+02'::timestamptz, null);
  ped := (r ->> 'pedido_id')::uuid;

  select cantidad, reservado into cant0, res0
    from saldos where lote_id = lote and ubicacion_id = 'ONLINE';

  ---------------------------------------------------------------------------
  -- 1) Escanear algo que no es del pedido: el error más común al preparar.
  ---------------------------------------------------------------------------
  begin
    perform servir_linea_escaneada('bbbbbbbb-0000-4000-8000-0000000000f1',
              ped, otro, 1, u, now());
    raise warning 'FALLO: aceptó un lote que no es del pedido'; errores := errores + 1;
  exception when others then null;
  end;

  ---------------------------------------------------------------------------
  -- 2) Preparar SÍ descuenta, y suelta la reserva correspondiente.
  ---------------------------------------------------------------------------
  r := servir_linea_escaneada('bbbbbbbb-0000-4000-8000-000000000002',
         ped, lote, 2, u, '2026-09-19T10:00:00+02'::timestamptz);

  select cantidad, reservado into cant1, res1
    from saldos where lote_id = lote and ubicacion_id = 'ONLINE';

  if cant0 - cant1 <> 2 then
    raise warning 'FALLO: preparar descontó % en vez de 2', cant0 - cant1; errores := errores + 1;
  end if;
  if res0 - res1 <> 2 then
    raise warning 'FALLO: soltó % de reserva en vez de 2', res0 - res1; errores := errores + 1;
  end if;
  if (r ->> 'completo')::boolean is not false then
    raise warning 'FALLO: dice que está completo y falta uno'; errores := errores + 1;
  end if;
  if (select estado from pedidos where pedido_id = ped) <> 'PREPARANDO' then
    raise warning 'FALLO: el pedido no pasó a PREPARANDO'; errores := errores + 1;
  end if;

  -- Repetir el mismo escaneo no descuenta dos veces.
  perform servir_linea_escaneada('bbbbbbbb-0000-4000-8000-000000000002',
            ped, lote, 2, u, '2026-09-19T10:00:00+02'::timestamptz);
  if (select cantidad from saldos where lote_id = lote and ubicacion_id = 'ONLINE') <> cant1 then
    raise warning 'FALLO: repetir el escaneo volvió a descontar'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 3) Pasarse de la cantidad pedida.
  ---------------------------------------------------------------------------
  begin
    perform servir_linea_escaneada('bbbbbbbb-0000-4000-8000-0000000000f2',
              ped, lote, 5, u, now());
    raise warning 'FALLO: sirvió más de lo pedido'; errores := errores + 1;
  exception when others then null;
  end;

  ---------------------------------------------------------------------------
  -- 4) Empaquetar NO toca el inventario. Es lo importante de todo esto.
  ---------------------------------------------------------------------------
  select count(*) into movs0 from movimientos;

  bulto := (crear_bulto(ped, 'C1') ->> 'bulto_id')::uuid;
  perform anadir_a_bulto(bulto, lote, 2);

  if (select count(*) from movimientos) <> movs0 then
    raise warning 'FALLO: empaquetar escribió en el libro de movimientos';
    errores := errores + 1;
  end if;
  if (select cantidad from saldos where lote_id = lote and ubicacion_id = 'ONLINE') <> cant1 then
    raise warning 'FALLO: empaquetar cambió el stock'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 5) La caja avisa antes de que no cierre.
  ---------------------------------------------------------------------------
  insert into capacidad_caja (caja_id, formato_id, unidades_max)
  values ('C1', 'F250G', 4) on conflict do nothing;

  begin
    perform anadir_a_bulto(bulto, lote, 5);
    raise warning 'FALLO: dejó meter más de lo que cabe en la caja'; errores := errores + 1;
  exception when others then null;
  end;

  ---------------------------------------------------------------------------
  -- 6) Cerrar calcula el peso: café más caja vacía.
  ---------------------------------------------------------------------------
  r := cerrar_bulto(bulto, 'SEG-12345');
  -- 2 paquetes de 250 g = 500 g, más 120 g de caja pequeña.
  if (r ->> 'peso_g')::int <> 620 then
    raise warning 'FALLO: el peso calculado es % y debería ser 620 g', r ->> 'peso_g';
    errores := errores + 1;
  end if;

  begin
    perform anadir_a_bulto(bulto, lote, 1);
    raise warning 'FALLO: dejó añadir a un bulto ya cerrado'; errores := errores + 1;
  exception when others then null;
  end;

  ---------------------------------------------------------------------------
  -- 7) Terminar el pedido con el último paquete.
  ---------------------------------------------------------------------------
  r := servir_linea_escaneada('bbbbbbbb-0000-4000-8000-000000000003',
         ped, lote, 1, u, '2026-09-19T11:00:00+02'::timestamptz);

  if (r ->> 'completo')::boolean is not true then
    raise warning 'FALLO: no reconoce que el pedido está completo'; errores := errores + 1;
  end if;
  if (select estado from pedidos where pedido_id = ped) <> 'SERVIDO' then
    raise warning 'FALLO: el pedido no quedó como SERVIDO'; errores := errores + 1;
  end if;
  if (select reservado from saldos where lote_id = lote and ubicacion_id = 'ONLINE') <> res0 - 3 then
    raise warning 'FALLO: quedaron reservas sin soltar'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 8) La caja que se sugiere es la más pequeña donde cabe todo.
  ---------------------------------------------------------------------------
  insert into capacidad_caja (caja_id, formato_id, unidades_max) values
    ('C2', 'F250G', 12), ('C3', 'F250G', 30)
  on conflict do nothing;

  r := registrar_pedido_canal(
         'bbbbbbbb-0000-4000-8000-000000000004', 'ONLINE',
         jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 6, 'precio_unit', 12.5)),
         'Online', 'woocommerce', 'woo-7002', null, '7002', 'woocommerce', null,
         '2026-09-19T12:00:00+02'::timestamptz, null);

  -- Seis no caben en la pequeña (4) pero sí en la mediana (12).
  if (sugerir_caja((r ->> 'pedido_id')::uuid) ->> 'caja_id') <> 'C2' then
    raise warning 'FALLO: sugiere % en vez de la mediana',
      sugerir_caja((r ->> 'pedido_id')::uuid) ->> 'caja_id';
    errores := errores + 1;
  end if;

  if errores > 0 then
    raise exception 'BULTOS: % comprobaciones fallidas', errores;
  end if;
  raise notice 'BULTOS ✓  preparar descuenta y suelta reserva, empaquetar no toca el libro, peso calculado y caja sugerida';
end $$;
