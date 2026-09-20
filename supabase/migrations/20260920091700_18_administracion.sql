-- ═══════════════════════════════════════════════════════════════════════════
--  18 · ADMINISTRACIÓN
--  Lo que faltaba para poder usar la app sin entrar al panel de Supabase:
--  dar de alta usuarios, asignar códigos EAN y editar parámetros.
-- ═══════════════════════════════════════════════════════════════════════════

insert into parametros (clave, valor, descripcion) values
  ('prefijo_gs1', '',
   'Prefijo de empresa que asigna GS1, con el 84 delante. Ej.: 8412345'),
  ('ean_siguiente', '1',
   'Siguiente número de artículo al generar un EAN. No tocar a mano: bajarlo repetiría códigos')
on conflict (clave) do nothing;


/* ─────────────────────────── Usuarios ───────────────────────────
   El PIN nunca pasa por una tabla ni por un update suelto: entra por estas
   funciones, que lo cifran. Así no hay ningún camino por el que acabe en
   claro en un registro o en una copia de seguridad.
   ──────────────────────────────────────────────────────────────── */

create or replace function crear_usuario(p_nombre text, p_pin text, p_rol rol_usuario)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if not app.tiene_nivel('ADMIN') then
    raise exception 'Solo un administrador puede dar de alta usuarios.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_pin !~ '^[0-9]{4,8}$' then
    raise exception 'El PIN tiene que ser de 4 a 8 cifras.';
  end if;

  insert into usuarios (nombre, pin_hash, rol)
  values (btrim(p_nombre), app.hash_pin(p_pin), p_rol)
  returning usuario_id into v_id;

  return v_id;
end;
$$;

create or replace function cambiar_rol_usuario(p_usuario_id uuid, p_rol rol_usuario)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('ADMIN') then
    raise exception 'Solo un administrador puede cambiar perfiles.'
      using errcode = 'insufficient_privilege';
  end if;

  -- Quedarse sin ningún administrador dejaría el sistema sin quien lo
  -- gestione, y no habría forma de arreglarlo desde la propia app.
  if p_rol <> 'ADMIN' and not exists (
       select 1 from usuarios
        where rol = 'ADMIN' and activo and usuario_id <> p_usuario_id) then
    raise exception 'No puedes dejar el sistema sin ningún administrador activo.';
  end if;

  update usuarios set rol = p_rol where usuario_id = p_usuario_id;
  return found;
end;
$$;

create or replace function activar_usuario(p_usuario_id uuid, p_activo boolean)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('ADMIN') then
    raise exception 'Solo un administrador puede dar de baja usuarios.'
      using errcode = 'insufficient_privilege';
  end if;

  if not p_activo and not exists (
       select 1 from usuarios
        where rol = 'ADMIN' and activo and usuario_id <> p_usuario_id) then
    raise exception 'No puedes dejar el sistema sin ningún administrador activo.';
  end if;

  -- Dar de baja no borra: el histórico de quién hizo cada movimiento tiene
  -- que seguir teniendo nombre.
  update usuarios set activo = p_activo where usuario_id = p_usuario_id;
  return found;
end;
$$;

/** Listado para la pantalla de usuarios, con el estado de su bloqueo. */
create or replace function usuarios_administrables()
returns table (usuario_id uuid, nombre text, rol rol_usuario, activo boolean,
               creado_en timestamptz, fallos integer, bloqueado_hasta timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('ADMIN') then
    raise exception 'Solo un administrador puede ver los usuarios.'
      using errcode = 'insufficient_privilege';
  end if;

  return query
    select u.usuario_id, u.nombre, u.rol, u.activo, u.creado_en,
           coalesce(i.fallos, 0), i.bloqueado_hasta
      from usuarios u
      left join intentos_acceso i on i.usuario_id = u.usuario_id
     order by u.activo desc, u.nombre;
end;
$$;


/* ─────────────────────────── Códigos EAN-13 ───────────────────────────
   Los distribuidores y las grandes superficies no leen el QR interno:
   necesitan un EAN-13. Identifica el PRODUCTO, no el lote, así que se asigna
   una vez por referencia y ya no cambia.
   ──────────────────────────────────────────────────────────────── */

create or replace function app.ean13_completo(p_doce text)
returns text
language plpgsql
immutable
as $$
declare
  v_suma int := 0;
  v_i    int;
begin
  if p_doce !~ '^[0-9]{12}$' then
    raise exception 'Hacen falta exactamente 12 cifras.';
  end if;
  for v_i in 1..12 loop
    v_suma := v_suma + substr(p_doce, v_i, 1)::int * case when v_i % 2 = 0 then 3 else 1 end;
  end loop;
  return p_doce || ((10 - (v_suma % 10)) % 10)::text;
end;
$$;

create or replace function generar_ean(p_sku text)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_prefijo text;
  v_n       int;
  v_relleno int;
  v_ean     text;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para asignar códigos EAN.'
      using errcode = 'insufficient_privilege';
  end if;

  v_prefijo := app.parametro('prefijo_gs1', '');
  if v_prefijo !~ '^[0-9]{6,11}$' then
    raise exception 'Falta el prefijo de GS1, o no tiene entre 6 y 11 cifras. '
                    'Ponlo en Ajustes → Parámetros antes de generar códigos.';
  end if;

  -- El número de artículo rellena lo que quede hasta las 12 cifras; la
  -- decimotercera es el dígito de control.
  v_relleno := 12 - length(v_prefijo);

  loop
    v_n := app.parametro_int('ean_siguiente', 1);
    if v_n >= power(10, v_relleno) then
      raise exception 'Se han agotado los números de artículo para este prefijo.';
    end if;

    v_ean := app.ean13_completo(v_prefijo || lpad(v_n::text, v_relleno, '0'));

    -- El contador se sube siempre, se use o no: bajarlo repetiría códigos, y
    -- un EAN repetido en dos productos es un problema en la caja de la tienda.
    update parametros set valor = (v_n + 1)::text where clave = 'ean_siguiente';

    exit when not exists (select 1 from articulos where ean13 = v_ean);
  end loop;

  update articulos set ean13 = v_ean where sku = p_sku;
  if not found then
    raise exception 'El artículo % no existe.', p_sku;
  end if;

  return v_ean;
end;
$$;

create or replace function asignar_ean(p_sku text, p_ean text)
returns text
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para asignar códigos EAN.'
      using errcode = 'insufficient_privilege';
  end if;

  if p_ean is null or btrim(p_ean) = '' then
    update articulos set ean13 = null where sku = p_sku;
    return null;
  end if;

  -- Se comprueba el dígito de control antes de aceptarlo: así no se cuela un
  -- código mal copiado que después falle en la caja de El Corte Inglés.
  if not app.ean13_valido(btrim(p_ean)) then
    raise exception 'Ese EAN-13 no es válido: el dígito de control no cuadra.';
  end if;

  update articulos set ean13 = btrim(p_ean) where sku = p_sku;
  if not found then
    raise exception 'El artículo % no existe.', p_sku;
  end if;

  return btrim(p_ean);
end;
$$;

grant execute on function
  crear_usuario(text, text, rol_usuario),
  cambiar_rol_usuario(uuid, rol_usuario),
  activar_usuario(uuid, boolean),
  usuarios_administrables(),
  generar_ean(text),
  asignar_ean(text, text)
to authenticated;
