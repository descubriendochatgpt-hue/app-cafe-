-- ═══════════════════════════════════════════════════════════════════════════
--  CRITERIO: «El stock en depósito cuadra con lo servido menos lo reportado
--             como vendido menos lo devuelto.»
--
--  Se reproduce el ciclo completo de El Corte Inglés en modo manual:
--  entrega → informe de ventas → devolución de lo no vendido.
-- ═══════════════════════════════════════════════════════════════════════════
set app.rol = 'ADMIN';

do $$
declare
  u       uuid := (select usuario_id from usuarios limit 1);
  lote    text := 'CAF-ETHYIR-250-260905-A';
  d       record;
  fallos  int := 0;
begin
  -- Punto de partida: 18 servidos en depósito, nada vendido ni devuelto.
  select * into d from v_deposito where lote_id = lote and ubicacion_id = 'DEPOSITO_ECI';
  if d.servido <> 18 or d.saldo <> 18 then
    raise warning 'FALLO: tras la entrega debería haber 18 servidos y 18 de saldo (hay %, %)',
      d.servido, d.saldo;
    fallos := fallos + 1;
  end if;

  -- Llega el informe mensual: ECI dice que ha vendido 11. AHORA es cuando
  -- sale del inventario, y no cuando se entregó.
  perform registrar_venta(
    p_operacion_id => '77777777-7777-4777-8777-000000000001',
    p_ubicacion_id => 'DEPOSITO_ECI',
    p_lineas => jsonb_build_array(jsonb_build_object(
                  'sku','ETHYIR-250-GR','cantidad',11,'precio_unit',12.50)),
    p_canal => 'El Corte Inglés',
    p_origen => 'eci', p_origen_id => 'informe-2026-09',
    p_usuario_id => u, p_ocurrido_en => '2026-09-30T23:00:00+02'::timestamptz,
    p_nota => 'Informe de ventas de depósito, septiembre');

  -- Lo no vendido vuelve al almacén propio: es un traslado de vuelta.
  perform registrar_traslado('77777777-7777-4777-8777-000000000002',
            lote, 'DEPOSITO_ECI', 'ALMACEN', 4, u,
            '2026-10-02T10:00:00+02'::timestamptz, 'Devolución de lo no vendido');

  select * into d from v_deposito where lote_id = lote and ubicacion_id = 'DEPOSITO_ECI';

  -- 18 servidos − 11 vendidos − 4 devueltos = 3
  if d.servido <> 18 then
    raise warning 'FALLO: servido = % (esperado 18)', d.servido; fallos := fallos + 1;
  end if;
  if d.vendido <> 11 then
    raise warning 'FALLO: vendido = % (esperado 11)', d.vendido; fallos := fallos + 1;
  end if;
  if d.devuelto <> 4 then
    raise warning 'FALLO: devuelto = % (esperado 4)', d.devuelto; fallos := fallos + 1;
  end if;
  if d.saldo <> 3 then
    raise warning 'FALLO: saldo = % (esperado 3)', d.saldo; fallos := fallos + 1;
  end if;
  if d.descuadre <> 0 then
    raise warning 'FALLO: descuadre = % (tiene que ser 0)', d.descuadre; fallos := fallos + 1;
  end if;

  -- Y lo importante: entregar NO restó del inventario total de la empresa.
  -- Los 18 salieron del almacén pero siguieron siendo nuestros; solo los 11
  -- reportados como vendidos han desaparecido del stock.
  --   65 producidos
  --  − 3 vendidos en tienda   − 4 en el mercado   − 2 por la web
  --  − 11 reportados por ECI  − 1 de merma        − 1 del recuento
  --  = 43. Los 18 entregados a ECI NO restan: cambiaron de sitio, no de dueño.
  if (select sum(cantidad) from saldos where sku = 'ETHYIR-250-GR')
     <> 65 - 3 - 4 - 2 - 11 - 1 - 1 then
    raise warning 'FALLO: el stock total de ETHYIR-250-GR no cuadra: %',
      (select sum(cantidad) from saldos where sku = 'ETHYIR-250-GR');
    fallos := fallos + 1;
  end if;

  if fallos > 0 then
    raise exception 'DEPÓSITO: % comprobaciones fallidas', fallos;
  end if;

  raise notice 'DEPÓSITO ✓  servido 18 − vendido 11 − devuelto 4 = saldo 3, descuadre 0';
end $$;
