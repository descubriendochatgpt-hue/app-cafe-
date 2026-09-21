-- ═══════════════════════════════════════════════════════════════════════════
--  24 · LAS VISTAS, CON LOS PERMISOS DE QUIEN PREGUNTA
--
--  Una vista de Postgres se ejecuta, por defecto, con los permisos de QUIEN
--  LA CREÓ, no de quien la consulta. Eso significa que una vista sobre una
--  tabla con RLS se salta esa RLS: quien pueda leer la vista ve todas las
--  filas, las suyas y las demás.
--
--  No es un detalle teórico. Es el aviso que da Supabase nada más montar el
--  esquema, y tiene razón en darlo: es la forma más silenciosa de abrir un
--  agujero, porque la política sigue ahí, escrita y aparentemente vigente,
--  pero no se evalúa.
--
--  `security_invoker` invierte eso: la vista pasa a ejecutarse con los
--  permisos de quien pregunta, y las políticas vuelven a aplicarse.
--
--  LAS DOS EXCEPCIONES, Y POR QUÉ LO SON
--
--  `pedidos_operativo` y `pedido_lineas_operativo` se quedan como estaban, a
--  propósito. Existen para que un operario vea los pedidos SIN los importes:
--  la tabla `pedidos` está cerrada a GESTOR por RLS —si se abriera, el
--  operario podría consultarla directamente y leer el total—, y la vista es
--  la ventana estrecha que se le deja abierta. Ahí saltarse RLS no es el
--  fallo: es el mecanismo, y la seguridad la da que la vista no seleccione
--  ninguna columna de dinero.
--
--  Dicho de otro modo: de las nueve vistas, siete no tenían ningún motivo
--  para saltarse RLS y lo hacían igual. Estas son esas siete.
-- ═══════════════════════════════════════════════════════════════════════════

alter view v_stock         set (security_invoker = true);
alter view v_frescura      set (security_invoker = true);
alter view v_deposito      set (security_invoker = true);
alter view v_trazabilidad  set (security_invoker = true);
alter view v_lote_detalle  set (security_invoker = true);
alter view v_saldo_detalle set (security_invoker = true);
alter view eventos_muertos set (security_invoker = true);

comment on view pedidos_operativo is
  'Pedidos sin importes, para el operario. Se ejecuta con los permisos de '
  'quien la creó A PROPÓSITO: la tabla está cerrada a GESTOR por RLS y esta '
  'es la ventana estrecha que se deja abierta. Si algún día se le añade una '
  'columna de dinero, deja de ser segura. Ver migración 24.';

comment on view pedido_lineas_operativo is
  'Líneas sin importes, para el operario. Misma excepción deliberada que '
  'pedidos_operativo. Ver migración 24.';
