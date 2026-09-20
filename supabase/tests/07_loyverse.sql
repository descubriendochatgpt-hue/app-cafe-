-- ═══════════════════════════════════════════════════════════════════════════
--  CONECTOR: cola de eventos y devoluciones.
--
--  Comprueba lo que de verdad pasa en producción: webhooks repetidos, eventos
--  que fallan y se reintentan, y devoluciones que tienen que volver a los
--  mismos lotes de los que salieron.
-- ═══════════════════════════════════════════════════════════════════════════
set app.rol = 'ADMIN';

do $$
declare
  u        uuid := (select usuario_id from usuarios limit 1);
  ev1      jsonb;
  ev2      jsonb;
  tomados  int;
  intentos int;
  incid    int;
  lote_eth text := 'CAF-ETHYIR-250-260905-A';
  antes    numeric;
  despues  numeric;
  r        jsonb;
  fallos   int := 0;
begin
  ---------------------------------------------------------------------------
  -- 1) El mismo recibo, dos veces: Loyverse reenvía y la consulta periódica
  --    lo vuelve a traer. Tiene que quedarse en uno.
  ---------------------------------------------------------------------------
  ev1 := recibir_evento('loyverse', 'receipt', 'r-7001',
           '{"receipt_number":"r-7001","receipt_type":"SALE"}'::jsonb);
  ev2 := recibir_evento('loyverse', 'receipt', 'r-7001',
           '{"receipt_number":"r-7001","receipt_type":"SALE"}'::jsonb);

  if (ev1 ->> 'nuevo')::boolean is not true then
    raise warning 'FALLO: el primer envío no se marcó como nuevo'; fallos := fallos + 1;
  end if;
  if (ev2 ->> 'nuevo')::boolean is not false then
    raise warning 'FALLO: el reenvío se tomó como un evento nuevo'; fallos := fallos + 1;
  end if;
  if (ev1 ->> 'evento_id') <> (ev2 ->> 'evento_id') then
    raise warning 'FALLO: el reenvío creó un evento distinto'; fallos := fallos + 1;
  end if;
  if (select count(*) from eventos_entrada where origen_id = 'r-7001') <> 1 then
    raise warning 'FALLO: hay más de un evento para el mismo recibo'; fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 2) Tomar la cola reserva el evento y cuenta el intento ANTES de
  --    procesarlo, para que un proceso que se cuelgue no lo repita sin fin.
  ---------------------------------------------------------------------------
  select count(*) into tomados from tomar_eventos('loyverse', 10);
  if tomados <> 1 then
    raise warning 'FALLO: tomar_eventos devolvió % eventos, esperaba 1', tomados;
    fallos := fallos + 1;
  end if;

  select e.intentos into intentos from eventos_entrada e where origen_id = 'r-7001';
  if intentos <> 1 then
    raise warning 'FALLO: intentos = % tras tomarlo una vez', intentos; fallos := fallos + 1;
  end if;

  -- Recién tomado, no vuelve a salir: está en espera.
  if (select count(*) from tomar_eventos('loyverse', 10)) <> 0 then
    raise warning 'FALLO: un evento recién tomado ha vuelto a salir'; fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 3) Ocho fallos agotan los reintentos y abren una incidencia: deja de ser
  --    un problema técnico y pasa a ser algo que alguien tiene que mirar.
  ---------------------------------------------------------------------------
  for i in 1..8 loop
    update eventos_entrada set proximo_intento_en = now() - interval '1 minute'
     where origen_id = 'r-7001';
    perform tomar_eventos('loyverse', 10);
    perform evento_fallido((ev1 ->> 'evento_id')::uuid, 'Artículo sin mapear');
  end loop;

  select count(*) into incid from incidencias
   where tipo = 'EVENTO_FALLIDO' and referencia = 'r-7001' and estado = 'ABIERTA';
  if incid <> 1 then
    raise warning 'FALLO: incidencias abiertas = %, esperaba 1', incid; fallos := fallos + 1;
  end if;

  -- Agotado, ya no se vuelve a tomar: no tiene sentido seguir intentándolo.
  update eventos_entrada set proximo_intento_en = now() - interval '1 hour'
   where origen_id = 'r-7001';
  if (select count(*) from tomar_eventos('loyverse', 10)) <> 0 then
    raise warning 'FALLO: un evento agotado se sigue reintentando'; fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 4) Reintentar tras mapear el artículo lo devuelve a la cola y da la
  --    incidencia por resuelta.
  ---------------------------------------------------------------------------
  perform reintentar_evento((ev1 ->> 'evento_id')::uuid);
  if (select estado from eventos_entrada where origen_id = 'r-7001') <> 'PENDIENTE' then
    raise warning 'FALLO: reintentar no devolvió el evento a la cola'; fallos := fallos + 1;
  end if;
  if (select count(*) from incidencias
       where referencia = 'r-7001' and estado = 'ABIERTA') <> 0 then
    raise warning 'FALLO: la incidencia sigue abierta tras reintentar'; fallos := fallos + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 5) Una devolución vuelve al MISMO lote del que salió la venta.
  --    En el escenario, el recibo 'receipt-8891' vendió 3 de ETHYIR en tienda.
  ---------------------------------------------------------------------------
  select cantidad into antes from saldos
   where lote_id = lote_eth and ubicacion_id = 'TIENDA';

  r := registrar_devolucion(
         '88888888-8888-4888-8888-000000000001',
         'TIENDA',
         jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 2)),
         'receipt-8891', 'loyverse', 'refund-8891', u,
         '2026-09-16T11:00:00+02'::timestamptz, 'Devolución del cliente');

  select cantidad into despues from saldos
   where lote_id = lote_eth and ubicacion_id = 'TIENDA';

  if despues - antes <> 2 then
    raise warning 'FALLO: la devolución dejó % en vez de sumar 2', despues - antes;
    fallos := fallos + 1;
  end if;
  if (r -> 'lotes' -> 0 ->> 'de') <> 'venta original' then
    raise warning 'FALLO: la devolución no se imputó al lote de la venta original (%)',
      r -> 'lotes' -> 0 ->> 'de';
    fallos := fallos + 1;
  end if;

  -- Y es idempotente: el mismo reembolso reenviado no devuelve el doble.
  perform registrar_devolucion(
    '88888888-8888-4888-8888-000000000001', 'TIENDA',
    jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 2)),
    'receipt-8891', 'loyverse', 'refund-8891', u,
    '2026-09-16T11:00:00+02'::timestamptz, null);

  if (select cantidad from saldos where lote_id = lote_eth and ubicacion_id = 'TIENDA') <> despues then
    raise warning 'FALLO: reenviar la devolución la contabilizó otra vez'; fallos := fallos + 1;
  end if;

  if fallos > 0 then
    raise exception 'CONECTOR: % comprobaciones fallidas', fallos;
  end if;

  raise notice 'CONECTOR ✓  reenvíos ignorados, 8 reintentos con espera, incidencia y reintento manual, devolución al lote original';
end $$;
