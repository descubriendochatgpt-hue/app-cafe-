-- ═══════════════════════════════════════════════════════════════════════════
--  17 · ENDURECIMIENTO TRAS LA REVISIÓN DE SEGURIDAD
--
--  Tres correcciones. La primera es la importante.
-- ═══════════════════════════════════════════════════════════════════════════


/* ═══════════════════════════════════════════════════════════════════════
   A · FUERZA BRUTA CONTRA EL PIN                                  (GRAVE)

   Un PIN de cuatro cifras son diez mil combinaciones. La aplicación está en
   internet, la lista de usuarios era pública y no había ningún freno: probar
   las diez mil era cuestión de minutos, y con ellas se entraba como
   administrador.

   Un PIN corto es la decisión correcta para trabajar con las manos sucias en
   un mercado. Lo que faltaba no era un PIN más largo, sino que probar salga
   caro.
   ═══════════════════════════════════════════════════════════════════════ */

create table intentos_acceso (
  usuario_id      uuid primary key references usuarios (usuario_id) on delete cascade,
  fallos          integer not null default 0 check (fallos >= 0),
  bloqueado_hasta timestamptz,
  ultimo_fallo    timestamptz
);

comment on table intentos_acceso is
  'Freno a la fuerza bruta. No se borra al acertar: se pone a cero, para que '
  'el histórico de bloqueos siga siendo consultable.';

alter table intentos_acceso enable row level security;
alter table intentos_acceso force row level security;
revoke all on intentos_acceso from anon, authenticated;
grant select on intentos_acceso to authenticated;
create policy leer_intentos on intentos_acceso
  for select to authenticated using (app.tiene_nivel('ADMIN'));

insert into parametros (clave, valor, descripcion) values
  ('acceso_fallos_antes_de_bloquear', '5',
   'Intentos fallidos seguidos antes de empezar a bloquear el acceso'),
  ('acceso_bloqueo_segundos', '60',
   'Segundos de bloqueo tras superar los fallos. Se duplica con cada tanda, hasta una hora')
on conflict (clave) do nothing;

/** Cuánto hay que esperar según los fallos acumulados. Crece deprisa: a los
    veinte fallos ya son horas, y probar diez mil PIN deja de ser viable. */
create or replace function app.espera_acceso(p_fallos int)
returns interval
language sql
stable
as $$
  select case
    when p_fallos < app.parametro_int('acceso_fallos_antes_de_bloquear', 5) then interval '0'
    else least(
      app.parametro_int('acceso_bloqueo_segundos', 60)
        * power(2, (p_fallos - app.parametro_int('acceso_fallos_antes_de_bloquear', 5)) / 3),
      3600)::int * interval '1 second'
  end;
$$;

create or replace function acceder(p_usuario_id uuid, p_pin text)
returns table (usuario_id uuid, nombre text, rol rol_usuario)
language plpgsql
volatile                       -- ahora escribe: lleva la cuenta de los fallos
security definer
-- `extensions` porque ahí vive pgcrypto en Supabase. Ver migración 01.
set search_path = public, extensions, pg_temp
as $$
declare
  v_bloqueado timestamptz;
  v_fallos    int;
  v_ok        boolean := false;
  v_u         record;
begin
  if p_pin !~ '^[0-9]{4,8}$' then
    return;
  end if;

  -- Se bloquea la fila para que veinte peticiones a la vez no cuenten como
  -- un solo intento. Sin esto, el atacante sortea el freno con concurrencia.
  -- Se nombra la restricción, no la columna: `usuario_id` también es una de
  -- las columnas que devuelve esta función, y PL/pgSQL no sabría a cuál de
  -- las dos se refiere.
  insert into intentos_acceso (usuario_id) values (p_usuario_id)
  on conflict on constraint intentos_acceso_pkey do nothing;

  select bloqueado_hasta, fallos into v_bloqueado, v_fallos
    from intentos_acceso where intentos_acceso.usuario_id = p_usuario_id
     for update;

  -- Mientras está bloqueado ni se mira el PIN: acertarlo por casualidad
  -- durante el bloqueo tampoco abre.
  if v_bloqueado is not null and v_bloqueado > now() then
    return;
  end if;

  select u.usuario_id, u.nombre, u.rol into v_u
    from usuarios u
   where u.usuario_id = p_usuario_id
     and u.activo
     and u.pin_hash = crypt(p_pin, u.pin_hash);

  v_ok := v_u.usuario_id is not null;

  if v_ok then
    update intentos_acceso
       set fallos = 0, bloqueado_hasta = null
     where intentos_acceso.usuario_id = p_usuario_id;

    return query select v_u.usuario_id, v_u.nombre, v_u.rol;
    -- `return query` NO termina la función: sin este `return`, un acceso
    -- correcto seguiría hasta la rama de fallo de abajo y se contaría como
    -- error. Un usuario legítimo acabaría bloqueándose solo.
    return;
  end if;

  update intentos_acceso
     set fallos = intentos_acceso.fallos + 1,
         ultimo_fallo = now(),
         bloqueado_hasta = case
           when app.espera_acceso(intentos_acceso.fallos + 1) > interval '0'
             then now() + app.espera_acceso(intentos_acceso.fallos + 1)
           else null
         end
   where intentos_acceso.usuario_id = p_usuario_id;

  return;
end;
$$;

comment on function acceder(uuid, text) is
  'Comprueba el PIN llevando la cuenta de los fallos. No distingue usuario '
  'inexistente, PIN erróneo ni cuenta bloqueada: las tres devuelven lo mismo.';

/** Cuánto queda de bloqueo, para poder decírselo a quien está esperando sin
    entender por qué no entra. No dice nada que el atacante no sepa ya. */
create or replace function espera_de_acceso(p_usuario_id uuid)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select greatest(0, ceil(extract(epoch from (bloqueado_hasta - now())))::int)
    from intentos_acceso
   where usuario_id = p_usuario_id and bloqueado_hasta > now();
$$;

/** Desbloquear a mano: alguien se ha equivocado cinco veces y está esperando. */
create or replace function desbloquear_acceso(p_usuario_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('ADMIN') then
    raise exception 'Solo un administrador puede desbloquear un acceso.'
      using errcode = 'insufficient_privilege';
  end if;
  update intentos_acceso set fallos = 0, bloqueado_hasta = null
   where usuario_id = p_usuario_id;
  return found;
end;
$$;

-- Cambia la forma de lo que devuelve, así que hay que retirar la anterior.
drop function if exists usuarios_para_acceso();

/* La lista de acceso deja de decir quién es administrador. Es lo primero que
   mira quien quiere entrar: saber a quién atacar le ahorraba la mitad del
   trabajo. El nombre hace falta para el desplegable; el rol, no. */
create or replace function usuarios_para_acceso()
returns table (usuario_id uuid, nombre text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select usuario_id, nombre from usuarios where activo order by nombre;
$$;

grant execute on function
  acceder(uuid, text), espera_de_acceso(uuid), usuarios_para_acceso()
to anon, authenticated;
grant execute on function desbloquear_acceso(uuid) to authenticated;


/* ═══════════════════════════════════════════════════════════════════════
   B · `stock_publicado` SIN RLS Y SIN PODER ESCRIBIRSE         (FUNCIONAL)

   Se creó después de la migración de permisos, así que se quedó fuera: era
   la única tabla sin RLS, y el conector de WooCommerce no podía escribirla.
   La publicación de stock habría fallado en cada vuelta.
   ═══════════════════════════════════════════════════════════════════════ */

alter table stock_publicado enable row level security;
alter table stock_publicado force row level security;
revoke all on stock_publicado from anon, authenticated;
grant select on stock_publicado to authenticated;

create policy leer_stock_publicado on stock_publicado
  for select to authenticated using (app.tiene_nivel('OPERARIO'));

/* Se escribe por función, como el resto: la tabla no recibe permiso directo. */
create or replace function anotar_stock_publicado(p_canal text, p_filas jsonb)
returns integer
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_n int;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para anotar el stock publicado.'
      using errcode = 'insufficient_privilege';
  end if;

  insert into stock_publicado (canal, sku, cantidad, publicado_en)
  select p_canal, f.sku, f.cantidad, now()
    from jsonb_to_recordset(p_filas) as f(sku text, cantidad numeric)
  on conflict (canal, sku) do update
    set cantidad = excluded.cantidad, publicado_en = excluded.publicado_en;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

grant execute on function anotar_stock_publicado(text, jsonb) to authenticated;


/* ═══════════════════════════════════════════════════════════════════════
   C · EL ENLACE DE PEDIDO ERA LEGIBLE POR CUALQUIER OPERARIO        (MEDIA)

   `clientes.token_pedido` es la credencial con la que un bar hace pedidos.
   La política de lectura de clientes la abría a cualquiera identificado.
   Que las rutas comprobaran el perfil no basta: la capa que manda es esta.

   Se pasa a permiso por columna: la credencial sale solo por las funciones
   que la gestionan, y solo para un gestor.
   ═══════════════════════════════════════════════════════════════════════ */

revoke select, update on clientes from authenticated;

grant select (cliente_id, nombre, tipo, nif, email, telefono, direccion, cp,
              poblacion, provincia, pais, descuento_pct, alta, activo, notas,
              creado_en)
  on clientes to authenticated;

-- El ciclo de vida del enlace vive en generar/revocar, no en un UPDATE suelto.
grant update (nombre, tipo, nif, email, telefono, direccion, cp, poblacion,
              provincia, pais, descuento_pct, alta, activo, notas)
  on clientes to authenticated;

create or replace function clientes_con_enlace()
returns table (cliente_id uuid, nombre text, tipo text, telefono text,
               descuento_pct numeric, token_creado_en timestamptz, token_pedido text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para ver los enlaces de pedido.'
      using errcode = 'insufficient_privilege';
  end if;

  return query
    select c.cliente_id, c.nombre, c.tipo, c.telefono,
           c.descuento_pct, c.token_creado_en, c.token_pedido
      from clientes c
     where c.activo
     order by c.nombre;
end;
$$;

grant execute on function clientes_con_enlace() to authenticated;
