-- ═══════════════════════════════════════════════════════════════════════════
--  BOT · quién puede preguntar, y como quién.
--
--  Al bot le puede escribir cualquiera que dé con él, así que lo que se
--  prueba aquí es sobre todo lo que NO debe ocurrir: que un desconocido
--  obtenga respuesta, que un código sirva dos veces, o que siga valiendo
--  después de generar otro.
-- ═══════════════════════════════════════════════════════════════════════════
set app.rol = 'ADMIN';

do $$
declare
  admin   uuid := (select usuario_id from usuarios limit 1);
  operario uuid;
  v_codigo text;
  v_viejo  text;
  r       jsonb;
  quien   jsonb;
  errores int := 0;
begin
  operario := crear_usuario('Marta', '5678', 'OPERARIO');

  ---------------------------------------------------------------------------
  -- 1) A quien no conocemos, nada. Ni siquiera que el bot existe.
  ---------------------------------------------------------------------------
  if quien_es_bot('telegram', 'desconocido-123') is not null then
    raise warning 'FALLO: un remitente desconocido obtiene identidad'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 2) Un código inventado no sirve.
  ---------------------------------------------------------------------------
  r := canjear_codigo_bot('telegram', 'tg-999', 'ZZZZZZ', null);
  if (r ->> 'ok')::boolean is not false then
    raise warning 'FALLO: un código inventado da el alta'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 3) El alta con un código bueno, generado por el operario.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', operario, 'rol', 'OPERARIO')::text, true);

  v_codigo := generar_codigo_bot() ->> 'codigo';
  if v_codigo !~ '^[A-Z0-9]{6}$' then
    raise warning 'FALLO: el código no tiene la forma esperada: %', v_codigo; errores := errores + 1;
  end if;

  perform set_config('request.jwt.claims', '{"rol":"SISTEMA"}', true);

  r := canjear_codigo_bot('telegram', 'tg-marta', v_codigo, 'marta_cafe');
  if (r ->> 'ok')::boolean is not true then
    raise warning 'FALLO: el código bueno no da el alta'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 4) Ahora sí la conoce, Y CON SU PERFIL. Es lo que hace que un operario
  --    no pueda sacar importes preguntándole al bot.
  ---------------------------------------------------------------------------
  quien := quien_es_bot('telegram', 'tg-marta');
  if quien is null then
    raise warning 'FALLO: tras el alta sigue sin reconocerla'; errores := errores + 1;
  elsif (quien ->> 'rol') <> 'OPERARIO' then
    raise warning 'FALLO: el perfil no es el del usuario (%), sino %',
      'OPERARIO', quien ->> 'rol';
    errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 5) El mismo código no sirve dos veces.
  ---------------------------------------------------------------------------
  r := canjear_codigo_bot('telegram', 'tg-otro', v_codigo, null);
  if (r ->> 'ok')::boolean is not false then
    raise warning 'FALLO: el código se pudo canjear dos veces'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 6) Generar uno nuevo apaga el anterior. Es lo que hace útil «generar
  --    otro» cuando el primero acabó donde no debía.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', admin, 'rol', 'ADMIN')::text, true);
  v_viejo := generar_codigo_bot() ->> 'codigo';
  perform generar_codigo_bot();

  perform set_config('request.jwt.claims', '{"rol":"SISTEMA"}', true);
  r := canjear_codigo_bot('telegram', 'tg-admin', v_viejo, null);
  if (r ->> 'ok')::boolean is not false then
    raise warning 'FALLO: el código anterior sigue valiendo tras generar otro';
    errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 7) Un código caducado tampoco.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', admin, 'rol', 'ADMIN')::text, true);
  v_codigo := generar_codigo_bot() ->> 'codigo';
  update bot_codigos set caduca_en = now() - interval '1 minute' where bot_codigos.codigo = v_codigo;

  perform set_config('request.jwt.claims', '{"rol":"SISTEMA"}', true);
  if (canjear_codigo_bot('telegram', 'tg-tarde', v_codigo, null) ->> 'ok')::boolean is not false then
    raise warning 'FALLO: un código caducado da el alta'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 8) Quitar el acceso tiene efecto inmediato.
  ---------------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', admin, 'rol', 'ADMIN')::text, true);
  perform revocar_bot('telegram', 'tg-marta');

  perform set_config('request.jwt.claims', '{"rol":"SISTEMA"}', true);
  if quien_es_bot('telegram', 'tg-marta') is not null then
    raise warning 'FALLO: sigue respondiendo a quien perdió el acceso'; errores := errores + 1;
  end if;

  ---------------------------------------------------------------------------
  -- 9) Un usuario de baja deja de poder preguntar, sin tocar el bot.
  ---------------------------------------------------------------------------
  perform canjear_codigo_bot('telegram', 'tg-marta2',
    (select bot_codigos.codigo from bot_codigos where usado_en is null limit 1), null);

  perform set_config('request.jwt.claims',
    json_build_object('sub', admin, 'rol', 'ADMIN')::text, true);
  perform activar_usuario(operario, false);

  perform set_config('request.jwt.claims', '{"rol":"SISTEMA"}', true);
  if quien_es_bot('telegram', 'tg-marta2') is not null then
    raise warning 'FALLO: un usuario de baja sigue pudiendo preguntar'; errores := errores + 1;
  end if;

  if errores > 0 then
    raise exception 'BOT: % comprobaciones fallidas', errores;
  end if;
  raise notice 'BOT ✓  desconocido sin respuesta, código de un solo uso que caduca y se invalida, y la baja del usuario cierra el acceso';
end $$;

reset role;
