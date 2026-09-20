-- ═══════════════════════════════════════════════════════════════════════════
--  CRITERIO: «Reprocesar un evento nunca duplica movimientos de stock.»
--
--  Se prueban las dos formas de repetición que ocurren de verdad:
--    a) la cola offline reenvía la MISMA operación (mismo UUID)
--    b) Loyverse reenvía el MISMO recibo con otro UUID de operación
-- ═══════════════════════════════════════════════════════════════════════════
set app.rol = 'ADMIN';

do $$
declare
  u              uuid := (select usuario_id from usuarios limit 1);
  movs_antes     bigint;
  movs_despues   bigint;
  saldo_antes    numeric;
  saldo_despues  numeric;
  r              jsonb;
  fallos         int := 0;
begin
  select count(*) into movs_antes from movimientos;
  select cantidad into saldo_antes from saldos
   where ubicacion_id = 'TIENDA' and sku = 'ETHYIR-250-GR';

  ---------------------------------------------------------------------------
  -- a) La cola offline sube dos veces la misma venta.
  ---------------------------------------------------------------------------
  r := registrar_venta(
         p_operacion_id => '44444444-4444-4444-8444-000000000001',
         p_ubicacion_id => 'TIENDA',
         p_lineas => jsonb_build_array(
                       jsonb_build_object('sku','ETHYIR-250-GR','cantidad',3,'precio_unit',12.50),
                       jsonb_build_object('sku','COLHUI-250-GR','cantidad',2,'precio_unit',11.00)),
         p_canal => 'Mostrador', p_origen => 'loyverse', p_origen_id => 'receipt-8891',
         p_usuario_id => u, p_ocurrido_en => '2026-09-14T18:20:00+02'::timestamptz);

  if (r ->> 'idempotente')::boolean is not true then
    raise warning 'FALLO: reenviar la misma operación no se detectó como duplicada';
    fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- b) Loyverse reenvía el recibo con otro UUID de operación.
  ---------------------------------------------------------------------------
  r := registrar_venta(
         p_operacion_id => gen_random_uuid(),           -- ← UUID distinto
         p_ubicacion_id => 'TIENDA',
         p_lineas => jsonb_build_array(
                       jsonb_build_object('sku','ETHYIR-250-GR','cantidad',3,'precio_unit',12.50)),
         p_canal => 'Mostrador', p_origen => 'loyverse', p_origen_id => 'receipt-8891',
         p_usuario_id => u, p_ocurrido_en => '2026-09-14T18:20:00+02'::timestamptz);

  if (r ->> 'idempotente')::boolean is not true then
    raise warning 'FALLO: el reenvío del mismo recibo de Loyverse se contabilizó otra vez';
    fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- c) Un tueste repetido tampoco duplica producción.
  ---------------------------------------------------------------------------
  r := registrar_tueste(
         '22222222-2222-4222-8222-000000000001',
         jsonb_build_array(jsonb_build_object('lote_id','VRD-ETHYIR-260901-A','cantidad',20)),
         jsonb_build_array(jsonb_build_object('sku','ETHYIR-250-GR','cantidad',65)),
         'ALMACEN', u, '2026-09-05T08:30:00+02'::timestamptz);

  if (r ->> 'idempotente')::boolean is not true then
    raise warning 'FALLO: el tueste repetido volvió a producir';
    fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  select count(*) into movs_despues from movimientos;
  select cantidad into saldo_despues from saldos
   where ubicacion_id = 'TIENDA' and sku = 'ETHYIR-250-GR';

  if movs_despues <> movs_antes then
    raise warning 'FALLO: el libro creció de % a % movimientos', movs_antes, movs_despues;
    fallos := fallos + 1;
  end if;

  if saldo_despues <> saldo_antes then
    raise warning 'FALLO: el stock cambió de % a %', saldo_antes, saldo_despues;
    fallos := fallos + 1;
  end if;

  if fallos > 0 then
    raise exception 'IDEMPOTENCIA: % comprobaciones fallidas', fallos;
  end if;

  raise notice 'IDEMPOTENCIA ✓  tres reprocesos, % movimientos intactos, stock intacto (%)',
    movs_antes, saldo_antes;
end $$;
