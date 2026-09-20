-- ═══════════════════════════════════════════════════════════════════════════
--  11 · ACCESO
--  Identificación por PIN, que es lo que funciona con las manos sucias en un
--  mercado. El PIN no viaja más allá de estas dos funciones y nunca sale de
--  la base en claro: se compara contra el hash y se responde sí o no.
-- ═══════════════════════════════════════════════════════════════════════════

/* Lista para el desplegable de acceso. No expone ni el hash ni nada
   aprovechable: solo quién puede entrar. */
create or replace function usuarios_para_acceso()
returns table (usuario_id uuid, nombre text, rol rol_usuario)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select usuario_id, nombre, rol
    from usuarios
   where activo
   order by nombre;
$$;

/* Comprueba el PIN. Devuelve los datos del usuario o nada.
   Es deliberado que no distinga entre "no existe" y "PIN incorrecto". */
create or replace function acceder(p_usuario_id uuid, p_pin text)
returns table (usuario_id uuid, nombre text, rol rol_usuario)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if p_pin !~ '^[0-9]{4,8}$' then
    return;
  end if;

  return query
    select u.usuario_id, u.nombre, u.rol
      from usuarios u
     where u.usuario_id = p_usuario_id
       and u.activo
       and u.pin_hash = crypt(p_pin, u.pin_hash);
end;
$$;

/* Cambiar el PIN propio, o el de otro si eres administrador. */
create or replace function cambiar_pin(p_usuario_id uuid, p_pin_nuevo text)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if p_pin_nuevo !~ '^[0-9]{4,8}$' then
    raise exception 'El PIN tiene que ser de 4 a 8 cifras.';
  end if;
  if p_usuario_id <> app.usuario_actual() and not app.tiene_nivel('ADMIN') then
    raise exception 'Solo un administrador puede cambiar el PIN de otra persona.'
      using errcode = 'insufficient_privilege';
  end if;

  update usuarios set pin_hash = app.hash_pin(p_pin_nuevo)
   where usuario_id = p_usuario_id and activo;

  return found;
end;
$$;

-- El desplegable de acceso se ve antes de identificarse; la comprobación del
-- PIN también tiene que poder llamarse sin sesión. Nada más.
grant execute on function usuarios_para_acceso() to anon, authenticated;
grant execute on function acceder(uuid, text) to anon, authenticated;
grant execute on function cambiar_pin(uuid, text) to authenticated;
