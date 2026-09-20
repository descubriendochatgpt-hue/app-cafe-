-- ═══════════════════════════════════════════════════════════════════════════
--  HOSTELERÍA: pedidos por enlace de WhatsApp.
--
--  El enlace ES la credencial, así que lo que se comprueba aquí es sobre todo
--  que no se pueda usar para lo que no es: pedir con un enlace revocado,
--  ponerse uno mismo el precio, o mandar el mismo pedido veinte veces.
-- ═══════════════════════════════════════════════════════════════════════════
set app.rol = 'ADMIN';

do $$
declare
  cli      uuid := 'cccccccc-0000-4000-8000-000000000001';
  token    text;
  cat      jsonb;
  r        jsonb;
  precio   numeric;
  reserva0 numeric; reserva1 numeric; cant0 numeric;
  lote     text := 'CAF-ETHYIR-250-260905-A';
  fallos   int := 0;
begin
  ---------------------------------------------------------------------------
  -- 1) El enlace se genera y sirve para ver el catálogo con SU precio.
  ---------------------------------------------------------------------------
  token := generar_enlace_pedido(cli);
  if token !~ '^[0-9a-f]{32}$' then
    raise warning 'FALLO: el token no tiene la forma esperada: %', token; fallos := fallos + 1;
  end if;

  cat := catalogo_pedido(token);
  if cat is null then
    raise warning 'FALLO: el enlace recién creado no devuelve catálogo'; fallos := fallos + 1;
  end if;
  if (cat -> 'cliente' ->> 'nombre') <> 'Cafetería La Plaza' then
    raise warning 'FALLO: el catálogo no identifica al cliente'; fallos := fallos + 1;
  end if;

  -- 12,50 € con el 10 % de descuento de este cliente = 11,25 €
  select (x ->> 'precio')::numeric into precio
    from jsonb_array_elements(cat -> 'articulos') x
   where x ->> 'sku' = 'ETHYIR-250-GR';
  if precio <> 11.25 then
    raise warning 'FALLO: el precio con descuento es % y debería ser 11.25', precio;
    fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 2) Un enlace inventado no dice nada. Ni qué falla, ni si el cliente existe.
  ---------------------------------------------------------------------------
  if catalogo_pedido('00000000000000000000000000000000') is not null then
    raise warning 'FALLO: un token inventado devuelve catálogo'; fallos := fallos + 1;
  end if;
  if catalogo_pedido('esto-no-es-un-token') is not null then
    raise warning 'FALLO: un token con formato inválido devuelve catálogo'; fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 3) Pedir reserva stock, y el precio lo pone el servidor.
  ---------------------------------------------------------------------------
  select cantidad, reservado into cant0, reserva0
    from saldos where lote_id = lote and ubicacion_id = 'ALMACEN';

  r := crear_pedido_hosteleria(
         'dddddddd-0000-4000-8000-000000000001', token,
         -- El formulario manda un precio ridículo a propósito: tiene que
         -- ignorarse. Si se aceptara, cualquiera con el enlace se pondría
         -- el precio que quisiera.
         jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR',
                                              'cantidad', 4, 'precio_unit', 0.01)),
         'Para el jueves', '2026-09-19T09:00:00+02'::timestamptz);

  if (r ->> 'numero') is null then
    raise warning 'FALLO: el pedido no devolvió número'; fallos := fallos + 1;
  end if;

  if (select precio_unit from pedido_lineas
       where pedido_id = (r ->> 'pedido_id')::uuid and sku = 'ETHYIR-250-GR') <> 11.25 then
    raise warning 'FALLO: se aceptó el precio que mandó el formulario'; fallos := fallos + 1;
  end if;

  select reservado into reserva1
    from saldos where lote_id = lote and ubicacion_id = 'ALMACEN';
  if reserva1 - reserva0 <> 4 then
    raise warning 'FALLO: reservó % en vez de 4', reserva1 - reserva0; fallos := fallos + 1;
  end if;
  if (select cantidad from saldos where lote_id = lote and ubicacion_id = 'ALMACEN') <> cant0 then
    raise warning 'FALLO: pedir descontó existencias, y solo debía reservar';
    fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 4) Líneas imposibles: se descartan en vez de colarse.
  ---------------------------------------------------------------------------
  begin
    perform crear_pedido_hosteleria(
      'dddddddd-0000-4000-8000-00000000000f', token,
      jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', -5)),
      null, now());
    raise warning 'FALLO: se admitió una cantidad negativa'; fallos := fallos + 1;
  exception when others then null;
  end;

  begin
    perform crear_pedido_hosteleria(
      'dddddddd-0000-4000-8000-00000000000e', token,
      jsonb_build_array(jsonb_build_object('sku', 'NO-EXISTE', 'cantidad', 2)),
      null, now());
    raise warning 'FALLO: se admitió un artículo inexistente'; fallos := fallos + 1;
  exception when others then null;
  end;

  ---------------------------------------------------------------------------
  -- 5) El freno a los envíos repetidos. El doble clic es más frecuente que
  --    el ataque, y el efecto sería el mismo: cuatro pedidos iguales.
  ---------------------------------------------------------------------------
  for i in 2..5 loop
    perform crear_pedido_hosteleria(
      ('dddddddd-0000-4000-8000-00000000001' || i)::uuid, token,
      jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 1)),
      null, now());
  end loop;

  begin
    perform crear_pedido_hosteleria(
      'dddddddd-0000-4000-8000-000000000099', token,
      jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 1)),
      null, now());
    raise warning 'FALLO: el sexto pedido en una hora pasó el freno'; fallos := fallos + 1;
  exception when others then null;
  end;

  ---------------------------------------------------------------------------
  -- 6) Revocar el enlace lo apaga en el acto, sin tocar a los demás clientes.
  ---------------------------------------------------------------------------
  perform revocar_enlace_pedido(cli);

  if catalogo_pedido(token) is not null then
    raise warning 'FALLO: el enlace revocado sigue devolviendo catálogo'; fallos := fallos + 1;
  end if;

  begin
    perform crear_pedido_hosteleria(
      'dddddddd-0000-4000-8000-000000000100', token,
      jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 1)),
      null, now());
    raise warning 'FALLO: se pudo pedir con un enlace revocado'; fallos := fallos + 1;
  exception when insufficient_privilege then null;
  end;

  -- Y se puede volver a dar uno nuevo, distinto del anterior.
  if generar_enlace_pedido(cli) = token then
    raise warning 'FALLO: el enlace regenerado es el mismo de antes'; fallos := fallos + 1;
  end if;

  if fallos > 0 then
    raise exception 'HOSTELERÍA: % comprobaciones fallidas', fallos;
  end if;

  raise notice 'HOSTELERÍA ✓  enlace con precio propio, precio del servidor, freno a repetidos y revocación inmediata';
end $$;
