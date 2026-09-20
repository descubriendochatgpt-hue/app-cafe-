-- ═══════════════════════════════════════════════════════════════════════════
--  19 · BOT DE CONSULTA
--
--  Preguntar por el negocio desde el móvil sin abrir la aplicación.
--
--  EL PROBLEMA DE FONDO, Y LA DECISIÓN QUE LO RESUELVE
--
--  A una cuenta de Instagram le escribe cualquiera. Si el bot respondiera a
--  quien le hable, un cliente podría preguntar cuánto stock hay, qué margen
--  se saca o qué se le vende a El Corte Inglés. Sería una fuga de datos del
--  negocio por un canal público.
--
--  Por eso el bot NO responde a nadie que no esté autorizado, y autorizarse
--  no es algo que uno pueda hacer solo: hace falta un código de un solo uso
--  que se genera desde dentro de la aplicación.
--
--  Y lo segundo: quien queda autorizado lo hace COMO UN USUARIO CONCRETO. El
--  bot consulta con SU perfil, así que un operario que pregunte por márgenes
--  no obtiene nada. No es el bot quien decide qué enseñar: son las mismas
--  políticas RLS de siempre.
-- ═══════════════════════════════════════════════════════════════════════════

create table bot_autorizados (
  canal       text not null check (canal in ('instagram', 'prueba')),
  id_externo  text not null,
  usuario_id  uuid not null references usuarios (usuario_id) on delete cascade,
  alias       text,
  creado_en   timestamptz not null default now(),
  ultimo_uso  timestamptz,
  consultas   integer not null default 0,
  primary key (canal, id_externo)
);

comment on table bot_autorizados is
  'Quién puede preguntarle al bot, y como quién. El perfil lo hereda del '
  'usuario: el bot no decide qué enseñar, lo deciden las políticas RLS.';

create index bot_por_usuario on bot_autorizados (usuario_id);

create table bot_codigos (
  codigo      text primary key check (codigo ~ '^[A-Z0-9]{6}$'),
  usuario_id  uuid not null references usuarios (usuario_id) on delete cascade,
  creado_en   timestamptz not null default now(),
  caduca_en   timestamptz not null,
  usado_en    timestamptz,
  usado_por   text
);

comment on table bot_codigos is
  'Código de un solo uso para darse de alta en el bot. Caduca pronto a '
  'propósito: es una credencial que viaja por un canal que no controlamos.';

alter table bot_autorizados enable row level security;
alter table bot_autorizados force row level security;
alter table bot_codigos enable row level security;
alter table bot_codigos force row level security;

revoke all on bot_autorizados, bot_codigos from anon, authenticated;
grant select on bot_autorizados to authenticated;

create policy leer_bot_autorizados on bot_autorizados
  for select to authenticated
  using (usuario_id = app.usuario_actual() or app.tiene_nivel('ADMIN'));

insert into parametros (clave, valor, descripcion) values
  ('bot_minutos_codigo', '15',
   'Minutos que vale un código de alta del bot antes de caducar'),
  ('bot_respuesta_desconocido',
   'Hola. Esta cuenta no atiende pedidos por mensaje directo; escríbenos y te contamos.',
   'Lo que se responde a quien no está autorizado. Vacío = no responder nada'),
  ('bot_consultas_max_hora', '60',
   'Consultas por persona y hora. Freno a un bucle o a un uso desbocado')
on conflict (clave) do nothing;


/* ─────────────────────────── Alta y baja ─────────────────────────── */

create or replace function generar_codigo_bot()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_codigo text;
  v_yo     uuid := app.usuario_actual();
  v_min    int  := app.parametro_int('bot_minutos_codigo', 15);
begin
  if not app.tiene_nivel('OPERARIO') or v_yo is null then
    raise exception 'Hay que identificarse para darse de alta en el bot.'
      using errcode = 'insufficient_privilege';
  end if;

  -- Sin letras ni cifras que se confundan al leerlas en una pantalla: ni O/0,
  -- ni I/1. Se teclea desde el móvil, mirando otra pantalla.
  loop
    v_codigo := string_agg(
      substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789',
             floor(random() * 32 + 1)::int, 1), '')
      from generate_series(1, 6);
    exit when not exists (select 1 from bot_codigos where codigo = v_codigo);
  end loop;

  -- Un código nuevo invalida los anteriores de esa persona: si el primero
  -- acabó donde no debía, generar otro lo apaga.
  delete from bot_codigos where usuario_id = v_yo and usado_en is null;

  insert into bot_codigos (codigo, usuario_id, caduca_en)
  values (v_codigo, v_yo, now() + (v_min || ' minutes')::interval);

  return jsonb_build_object('codigo', v_codigo, 'minutos', v_min);
end;
$$;

/** Canjea el código que alguien ha mandado por mensaje. Lo llama el servidor
    con perfil SISTEMA, porque quien escribe todavía no es nadie para nosotros. */
create or replace function canjear_codigo_bot(
  p_canal text, p_id_externo text, p_codigo text, p_alias text default null
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_usuario uuid;
  v_nombre  text;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Solo el sistema canjea códigos.' using errcode = 'insufficient_privilege';
  end if;

  select c.usuario_id into v_usuario
    from bot_codigos c
   where c.codigo = upper(btrim(p_codigo))
     and c.usado_en is null
     and c.caduca_en > now()
     for update;

  if v_usuario is null then
    return jsonb_build_object('ok', false);
  end if;

  update bot_codigos
     set usado_en = now(), usado_por = p_id_externo
   where codigo = upper(btrim(p_codigo));

  insert into bot_autorizados (canal, id_externo, usuario_id, alias)
  values (p_canal, p_id_externo, v_usuario, p_alias)
  on conflict (canal, id_externo) do update
    set usuario_id = excluded.usuario_id, alias = excluded.alias;

  select nombre into v_nombre from usuarios where usuario_id = v_usuario;
  return jsonb_build_object('ok', true, 'usuario_id', v_usuario, 'nombre', v_nombre);
end;
$$;

/** Quién es quien escribe, y con qué perfil. Devuelve nada si no está
    autorizado, si se le dio de baja o si superó el límite de consultas. */
create or replace function quien_es_bot(p_canal text, p_id_externo text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v record;
  v_max int := app.parametro_int('bot_consultas_max_hora', 60);
  v_recientes int;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Solo el sistema resuelve identidades del bot.'
      using errcode = 'insufficient_privilege';
  end if;

  select b.usuario_id, u.nombre, u.rol, u.activo
    into v
    from bot_autorizados b
    join usuarios u on u.usuario_id = b.usuario_id
   where b.canal = p_canal and b.id_externo = p_id_externo;

  if v.usuario_id is null or not v.activo then
    return null;
  end if;

  -- Un bucle entre dos bots, o alguien pulsando enviar sin parar, saldría
  -- caro en peticiones a la base y a Meta.
  select consultas into v_recientes
    from bot_autorizados
   where canal = p_canal and id_externo = p_id_externo
     and ultimo_uso > now() - interval '1 hour';

  if coalesce(v_recientes, 0) >= v_max then
    return jsonb_build_object('limitado', true);
  end if;

  update bot_autorizados
     set ultimo_uso = now(),
         consultas = case
           when ultimo_uso is null or ultimo_uso < now() - interval '1 hour' then 1
           else consultas + 1
         end
   where canal = p_canal and id_externo = p_id_externo;

  return jsonb_build_object(
    'usuario_id', v.usuario_id, 'nombre', v.nombre, 'rol', v.rol, 'limitado', false);
end;
$$;

create or replace function revocar_bot(p_canal text, p_id_externo text)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('ADMIN') then
    raise exception 'Solo un administrador puede revocar accesos al bot.'
      using errcode = 'insufficient_privilege';
  end if;
  delete from bot_autorizados where canal = p_canal and id_externo = p_id_externo;
  return found;
end;
$$;

create or replace function bot_autorizados_lista()
returns table (canal text, id_externo text, usuario_id uuid, nombre text,
               alias text, creado_en timestamptz, ultimo_uso timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('ADMIN') then
    raise exception 'Solo un administrador puede ver los accesos al bot.'
      using errcode = 'insufficient_privilege';
  end if;

  return query
    select b.canal, b.id_externo, b.usuario_id, u.nombre, b.alias, b.creado_en, b.ultimo_uso
      from bot_autorizados b join usuarios u on u.usuario_id = b.usuario_id
     order by b.creado_en desc;
end;
$$;

grant execute on function
  generar_codigo_bot(),
  canjear_codigo_bot(text, text, text, text),
  quien_es_bot(text, text),
  revocar_bot(text, text),
  bot_autorizados_lista()
to authenticated;
