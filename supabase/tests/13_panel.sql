-- ═══════════════════════════════════════════════════════════════════════════
--  PANEL · un resumen que no puede contradecir a los datos.
--
--  Un panel es peligroso precisamente porque se lee rápido y se cree. Aquí se
--  comprueban las dos cosas por las que un panel engaña: que cuente ventas que
--  no lo son, y que enseñe dinero a quien no debe verlo.
-- ═══════════════════════════════════════════════════════════════════════════
set app.rol = 'ADMIN';

do $$
declare
  u        uuid := (select usuario_id from usuarios limit 1);
  p        jsonb;
  dia      jsonb;
  ped      uuid;
  suma     numeric := 0;
  fechas   int;
  entradas int;
  antes    bigint;
  errores  int := 0;
begin
  ---------------------------------------------------------------------------
  -- 1) Un pedido confirmado NO es una venta. Todavía puede caerse, y contarlo
  --    infla la cifra justo en el número que más se mira.
  ---------------------------------------------------------------------------
  p := panel(365);
  antes := (p -> 'ventas' ->> 'pedidos')::bigint;

  p := registrar_pedido_canal(
         'cccccccc-0000-4000-8000-000000000001', 'ONLINE',
         jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 1, 'precio_unit', 12.5)),
         'Online', 'woocommerce', 'woo-9001', null, '9001', 'woocommerce', 'Tarjeta',
         now(), null);
  ped := (p ->> 'pedido_id')::uuid;

  p := panel(365);
  if (p -> 'ventas' ->> 'pedidos')::bigint <> antes then
    raise warning 'FALLO: cuenta como venta un pedido solo confirmado';
    errores := errores + 1;
  end if;

  -- Al servirlo sí cuenta.
  perform servir_reservas_pedido('cccccccc-0000-4000-8000-000000000002', ped, u, now());
  p := panel(365);
  if (p -> 'ventas' ->> 'pedidos')::bigint <> antes + 1 then
    raise warning 'FALLO: servir el pedido no lo contó como venta';
    errores := errores + 1;
  end if;

  -- Un segundo pedido servido EL MISMO DÍA. Sin esto la comprobación de la
  -- serie no comprueba nada: con un pedido por día, agrupar mal y agrupar
  -- bien dan el mismo resultado.
  p := registrar_pedido_canal(
         'cccccccc-0000-4000-8000-000000000003', 'ONLINE',
         jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 1, 'precio_unit', 12.5)),
         'Online', 'woocommerce', 'woo-9002', null, '9002', 'woocommerce', 'Tarjeta',
         now(), null);
  perform servir_reservas_pedido('cccccccc-0000-4000-8000-000000000004',
            (p ->> 'pedido_id')::uuid, u, now());
  p := panel(365);

  ---------------------------------------------------------------------------
  -- 2) La serie por día tiene UNA entrada por fecha, y suma lo mismo que el
  --    total. Si no, el gráfico y la cifra de arriba dirían cosas distintas.
  ---------------------------------------------------------------------------
  select count(*), count(distinct x ->> 'fecha')
    into entradas, fechas
    from jsonb_array_elements(p -> 'por_dia') as x;

  if entradas <> fechas then
    raise warning 'FALLO: la serie repite fechas (% entradas, % fechas)', entradas, fechas;
    errores := errores + 1;
  end if;

  -- Y cada fecha es un DÍA, no un instante. generate_series sobre fechas
  -- devuelve timestamp, así que sin el corte a ::date la serie salía como
  -- «2026-08-21T00:00:00+00:00»: quien la lee espera un día y se encuentra
  -- una hora y un huso pegados detrás.
  if exists (select 1 from jsonb_array_elements(p -> 'por_dia') as x
              where x ->> 'fecha' !~ '^\d{4}-\d{2}-\d{2}$') then
    raise warning 'FALLO: la serie trae fechas con hora, p. ej. %',
      (select x ->> 'fecha' from jsonb_array_elements(p -> 'por_dia') as x
        where x ->> 'fecha' !~ '^\d{4}-\d{2}-\d{2}$' limit 1);
    errores := errores + 1;
  end if;

  select coalesce(sum((x ->> 'total')::numeric), 0)
    into suma
    from jsonb_array_elements(p -> 'por_dia') as x;

  if suma <> (p -> 'ventas' ->> 'total')::numeric then
    raise warning 'FALLO: la serie suma % y el total dice %',
      suma, p -> 'ventas' ->> 'total';
    errores := errores + 1;
  end if;

  select coalesce(sum((x ->> 'pedidos')::bigint), 0)
    into antes
    from jsonb_array_elements(p -> 'por_dia') as x;
  if antes <> (p -> 'ventas' ->> 'pedidos')::bigint then
    raise warning 'FALLO: la serie cuenta % pedidos y el total %',
      antes, p -> 'ventas' ->> 'pedidos';
    errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 3) Por canal y top suman lo mismo que el total. Son el mismo dato
  --    partido de dos maneras.
  ---------------------------------------------------------------------------
  select coalesce(sum((x ->> 'pedidos')::bigint), 0) into antes
    from jsonb_array_elements(p -> 'por_canal') as x;
  if antes <> (p -> 'ventas' ->> 'pedidos')::bigint then
    raise warning 'FALLO: por canal suma % pedidos y el total %',
      antes, p -> 'ventas' ->> 'pedidos';
    errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 4) El stock del panel es el mismo que el de la vista de stock. El panel
  --    no guarda nada: si esto se separa, es que alguien lo ha cacheado.
  ---------------------------------------------------------------------------
  select coalesce(sum(s.cantidad), 0) into suma
    from saldos s join articulos a on a.sku = s.sku
   where s.cantidad > 0 and a.unidad = 'UD';
  if suma <> (p -> 'stock' ->> 'unidades')::numeric then
    raise warning 'FALLO: el panel dice % paquetes y los saldos dicen %',
      p -> 'stock' ->> 'unidades', suma;
    errores := errores + 1;
  end if;

  if errores = 0 then
    raise notice 'PANEL ✓ las cifras cuadran con el libro y con los pedidos';
  else
    raise exception 'PANEL: % fallo(s)', errores;
  end if;
end $$;


-- ═══════════════════════════════════════════════════════════════════════════
--  Un operario no recibe dinero. No es que la pantalla lo esconda: es que la
--  respuesta no lo trae, así que mirar la red no sirve de nada.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  p       jsonb;
  errores int := 0;
begin
  set local app.rol = 'OPERARIO';
  p := panel(30);

  if (p ->> 'con_importes')::boolean then
    raise warning 'FALLO: dice que el operario ve importes'; errores := errores + 1;
  end if;

  foreach p in array array[
    p -> 'ventas' -> 'total', p -> 'ventas' -> 'coste', p -> 'ventas' -> 'margen',
    p -> 'ventas' -> 'anterior', p -> 'stock' -> 'valor', p -> 'avisos' -> 'bajo_minimo'
  ] loop
    if p is not null and jsonb_typeof(p) <> 'null' then
      raise warning 'FALLO: al operario le llega un importe: %', p;
      errores := errores + 1;
    end if;
  end loop;

  -- Lo que sí puede ver: unidades y avisos. El panel le sirve igual.
  p := panel(30);
  if (p -> 'ventas' ->> 'pedidos') is null then
    raise warning 'FALLO: al operario no le llegan ni los pedidos'; errores := errores + 1;
  end if;

  if errores = 0 then
    raise notice 'PANEL ✓ el operario ve el panel sin una sola cifra de dinero';
  else
    raise exception 'PANEL (perfiles): % fallo(s)', errores;
  end if;
end $$;
