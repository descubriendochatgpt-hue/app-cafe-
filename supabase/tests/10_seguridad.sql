-- ═══════════════════════════════════════════════════════════════════════════
--  SEGURIDAD · las tres correcciones de la revisión, comprobadas.
--
--  Son pruebas de que un atacante NO puede hacer algo. Este tipo de test es
--  el que más falta hace: lo que se rompe al refactorizar no es la
--  funcionalidad, es la restricción que nadie volvió a mirar.
-- ═══════════════════════════════════════════════════════════════════════════
set app.rol = 'ADMIN';

do $$
declare
  admin    uuid := (select usuario_id from usuarios limit 1);
  cli      uuid := 'cccccccc-0000-4000-8000-000000000001';
  espera   int;
  entrados int;
  errores  int := 0;
begin
  ---------------------------------------------------------------------------
  -- A) El PIN aguanta un ataque por fuerza bruta.
  ---------------------------------------------------------------------------
  -- Cinco intentos malos: hasta aquí, sin bloqueo (uno se equivoca).
  for i in 1..4 loop
    perform acceder(admin, lpad(i::text, 4, '0'));
  end loop;

  if espera_de_acceso(admin) is not null then
    raise warning 'FALLO: bloquea antes de tiempo, con 4 fallos'; errores := errores + 1;
  end if;

  -- El PIN bueno todavía entra: equivocarse cuatro veces no te deja fuera.
  if (select count(*) from acceder(admin, '1234')) <> 1 then
    raise warning 'FALLO: el PIN correcto no entra tras 4 fallos'; errores := errores + 1;
  end if;

  -- Y acertar pone el contador a cero.
  if (select ia.fallos from intentos_acceso ia where ia.usuario_id = admin) <> 0 then
    raise warning 'FALLO: acertar no reinició el contador'; errores := errores + 1;
  end if;

  -- Ahora en serio: un atacante probando combinaciones.
  for i in 1..8 loop
    perform acceder(admin, lpad(i::text, 4, '9'));
  end loop;

  espera := espera_de_acceso(admin);
  if espera is null or espera <= 0 then
    raise warning 'FALLO: ocho intentos seguidos no bloquean nada'; errores := errores + 1;
  end if;

  -- Y lo importante: durante el bloqueo, NI SIQUIERA EL PIN BUENO abre.
  -- Si no fuera así, el atacante seguiría probando y el bloqueo no serviría.
  if (select count(*) from acceder(admin, '1234')) <> 0 then
    raise warning 'FALLO: el bloqueo no impide entrar con el PIN correcto';
    errores := errores + 1;
  end if;

  perform desbloquear_acceso(admin);
  if (select count(*) from acceder(admin, '1234')) <> 1 then
    raise warning 'FALLO: desbloquear no devuelve el acceso'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- B) La lista de acceso ya no dice quién es administrador.
  ---------------------------------------------------------------------------
  if exists (
    select 1 from information_schema.routines r
      join information_schema.parameters p on p.specific_name = r.specific_name
     where r.routine_name = 'usuarios_para_acceso' and p.parameter_name = 'rol'
  ) then
    raise warning 'FALLO: la lista pública sigue exponiendo el rol'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- C) El conector puede anotar lo publicado, y solo por la función.
  ---------------------------------------------------------------------------
  if anotar_stock_publicado('woocommerce',
       jsonb_build_array(jsonb_build_object('sku', 'ETHYIR-250-GR', 'cantidad', 7))) <> 1 then
    raise warning 'FALLO: no se pudo anotar el stock publicado'; errores := errores + 1;
  end if;

  if errores > 0 then
    raise exception 'SEGURIDAD: % comprobaciones fallidas', errores;
  end if;
  raise notice 'SEGURIDAD ✓  bloqueo tras fallos repetidos (% s), rol oculto en la lista de acceso', espera;
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- D) Lo que NO puede hacer cada rol. Fuera del bloque, con roles de verdad.
-- ─────────────────────────────────────────────────────────────────────────
do $$
declare errores int := 0;
begin
  if not exists (select 1 from pg_roles where rolname = 'prueba_operario') then
    create role prueba_operario;
    grant authenticated to prueba_operario;
  end if;
  if errores > 0 then null; end if;
end $$;

set role prueba_operario;
set request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","rol":"OPERARIO","role":"authenticated"}';

do $$
declare errores int := 0;
begin
  -- El enlace de pedido es una credencial: un operario no tiene por qué verla.
  begin
    perform token_pedido from clientes limit 1;
    raise warning 'FALLO: un operario puede leer los enlaces de pedido'; errores := errores + 1;
  exception when insufficient_privilege then null;
  end;

  begin
    perform clientes_con_enlace();
    raise warning 'FALLO: un operario puede listar los enlaces'; errores := errores + 1;
  exception when insufficient_privilege then null;
  end;

  -- Pero sigue viendo a los clientes, que los necesita para trabajar.
  if (select count(*) from clientes) = 0 then
    raise warning 'FALLO: un operario ya no ve ningún cliente'; errores := errores + 1;
  end if;

  -- Y no puede escribir en las tablas que publican stock.
  begin
    insert into stock_publicado (canal, sku, cantidad)
      values ('woocommerce', 'ETHYIR-250-GR', 999);
    raise warning 'FALLO: un operario puede escribir stock_publicado'; errores := errores + 1;
  exception when insufficient_privilege then null;
  end;

  begin
    perform anotar_stock_publicado('woocommerce', '[]'::jsonb);
    raise warning 'FALLO: un operario puede anotar stock publicado'; errores := errores + 1;
  exception when insufficient_privilege then null;
  end;

  if errores > 0 then
    raise exception 'SEGURIDAD (roles): % comprobaciones fallidas', errores;
  end if;
  raise notice 'SEGURIDAD ✓  el operario ve clientes pero no sus enlaces, y no publica stock';
end $$;

reset role;


-- ═══════════════════════════════════════════════════════════════════════════
--  Las vistas no se saltan RLS, salvo las dos que lo hacen a propósito.
--
--  Una vista corre con los permisos de quien la creó mientras no se le diga
--  lo contrario, y entonces las políticas de las tablas de debajo dejan de
--  evaluarse sin que nada lo avise. Esta prueba existe para que añadir una
--  vista nueva y olvidarse de `security_invoker` falle aquí y no en Supabase.
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare
  v        record;
  sueltas  text := '';
  errores  int := 0;
begin
  for v in
    select c.relname,
           coalesce((select option_value from pg_options_to_table(c.reloptions)
                      where option_name = 'security_invoker'), 'off') as invoker
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'v'
       -- Las dos excepciones deliberadas: son la ventana sin importes que se
       -- le deja al operario sobre una tabla cerrada a GESTOR.
       and c.relname not in ('pedidos_operativo', 'pedido_lineas_operativo')
  loop
    if v.invoker <> 'true' then
      sueltas := sueltas || ' ' || v.relname;
      errores := errores + 1;
    end if;
  end loop;

  if errores > 0 then
    raise warning 'FALLO: estas vistas se saltan RLS sin motivo:%', sueltas;
    raise exception 'SEGURIDAD (vistas): % vista(s) sin security_invoker', errores;
  end if;

  raise notice 'SEGURIDAD ✓  las vistas respetan RLS, salvo las dos excepciones documentadas';
end $$;
