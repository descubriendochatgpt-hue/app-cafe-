-- ═══════════════════════════════════════════════════════════════════════════
--  20 · EL BOT PASA A TELEGRAM
--
--  Se cambia Instagram por Telegram. No es un capricho: Instagram exige una
--  cuenta profesional enlazada a una página de Facebook, una app de Meta y
--  su revisión, que tarda. Con Telegram se habla con @BotFather, se copia un
--  token y funciona en dos minutos.
--
--  Además encaja mejor con lo que es esto:
--    · los mensajes son privados por naturaleza, no un buzón público al que
--      escribe cualquier cliente;
--    · hay enlaces de alta (t.me/elbot?start=CODIGO) que evitan teclear el
--      código mirando otra pantalla;
--    · el webhook se firma con un secreto que elegimos nosotros.
--
--  Lo que NO cambia: quién puede preguntar y con qué perfil. Esa parte no
--  dependía del canal, y por eso el cambio es este fichero y poco más.
-- ═══════════════════════════════════════════════════════════════════════════

-- No hay nada en producción todavía; si lo hubiera, esto migraría las filas
-- en vez de asumir que no las hay.
delete from bot_autorizados where canal = 'instagram';
delete from bot_codigos where usado_por is not null;

alter table bot_autorizados drop constraint bot_autorizados_canal_check;
alter table bot_autorizados add constraint bot_autorizados_canal_check
  check (canal in ('telegram', 'prueba'));

update parametros
   set descripcion = 'Lo que se responde a quien no está autorizado. Vacío = no responder nada'
 where clave = 'bot_respuesta_desconocido';

insert into parametros (clave, valor, descripcion) values
  ('telegram_usuario_bot', '',
   'Nombre del bot en Telegram, sin la arroba. Se usa para el enlace de alta')
on conflict (clave) do nothing;
