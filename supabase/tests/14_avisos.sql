-- ═══════════════════════════════════════════════════════════════════════════
--  AVISOS · un correo al día, ni dos ni ninguno.
--
--  Lo que se comprueba aquí es lo que distingue un aviso útil de una molestia:
--  que no se repita, que no se pierda si el proveedor falla, y que lleve los
--  nombres de las cosas en vez de solo contarlas.
-- ═══════════════════════════════════════════════════════════════════════════
set app.rol = 'ADMIN';

do $$
declare
  r        jsonb;
  ok1      boolean;
  ok2      boolean;
  errores  int := 0;
begin
  r := resumen_diario(current_date - 1);

  ---------------------------------------------------------------------------
  -- 1) El primer envío del día se reserva; el segundo no.
  ---------------------------------------------------------------------------
  ok1 := reservar_aviso_diario(current_date - 1, array['jefa@obrador.es'], r);
  ok2 := reservar_aviso_diario(current_date - 1, array['jefa@obrador.es'], r);

  if not ok1 then
    raise warning 'FALLO: el primer envío del día no se pudo reservar'; errores := errores + 1;
  end if;
  if ok2 then
    raise warning 'FALLO: se habría mandado un segundo correo el mismo día'; errores := errores + 1;
  end if;
  if (select count(*) from avisos_enviados where fecha = current_date - 1) <> 1 then
    raise warning 'FALLO: quedó más de un envío apuntado'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 2) Si el proveedor falla, soltar la reserva deja mandarlo otra vez. Sin
  --    esto, un fallo de red se comería el correo de ese día para siempre.
  ---------------------------------------------------------------------------
  perform soltar_aviso_diario(current_date - 1);
  if not reservar_aviso_diario(current_date - 1, array['jefa@obrador.es'], r) then
    raise warning 'FALLO: tras soltar la reserva no deja reintentar'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 3) El aviso lleva NOMBRES. «1 referencia bajo mínimos» obliga a abrir la
  --    aplicación; con el SKU dentro se decide desde el correo.
  ---------------------------------------------------------------------------
  if jsonb_array_length(r -> 'minimos') = 0 then
    raise warning 'FALLO: el escenario tiene un artículo bajo mínimos y no sale';
    errores := errores + 1;
  elsif (r -> 'minimos' -> 0 ->> 'sku') is null then
    raise warning 'FALLO: los mínimos salen sin el nombre del artículo';
    errores := errores + 1;
  end if;

  if (r ->> 'hay_avisos')::boolean is not true then
    raise warning 'FALLO: hay avisos y dice que no'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 4) Un día sin nada: el resumen existe igual, pero dice que no hay avisos
  --    solo si de verdad no los hay. Los mínimos son de hoy, no del día.
  ---------------------------------------------------------------------------
  if (resumen_diario('2020-01-01') -> 'ventas' ->> 'pedidos')::int <> 0 then
    raise warning 'FALLO: un día sin ventas devuelve pedidos'; errores := errores + 1;
  end if;

  if errores = 0 then
    raise notice 'AVISOS ✓ un correo por día, reintentable si falla, y con nombres dentro';
  else
    raise exception 'AVISOS: % fallo(s)', errores;
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════════════════
--  Y el correo lleva importes, así que un operario no puede pedirlo.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare errores int := 0;
begin
  set local app.rol = 'OPERARIO';
  begin
    perform resumen_diario(current_date - 1);
    raise warning 'FALLO: un operario obtuvo el resumen con importes';
    errores := errores + 1;
  exception when insufficient_privilege then null;
  end;

  begin
    perform reservar_aviso_diario(current_date, array['x@y.es'], '{}'::jsonb);
    raise warning 'FALLO: un operario pudo reservar un envío';
    errores := errores + 1;
  exception when insufficient_privilege then null;
  end;

  if errores = 0 then
    raise notice 'AVISOS ✓ el resumen con importes no sale para un operario';
  else
    raise exception 'AVISOS (perfiles): % fallo(s)', errores;
  end if;
end $$;
