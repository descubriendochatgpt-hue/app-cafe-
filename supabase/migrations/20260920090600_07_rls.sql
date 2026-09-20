-- ═══════════════════════════════════════════════════════════════════════════
--  07 · PERMISOS Y RLS
--
--  Dos capas, y la de abajo es la que manda:
--
--    1. GRANT — quién puede tocar cada tabla. El libro de movimientos no
--       tiene GRANT de INSERT para nadie: ni siquiera una política permisiva
--       podría abrirlo. La única vía de escritura son las funciones de la
--       migración 06, que son SECURITY DEFINER.
--    2. RLS — qué filas ve cada rol. Aquí se aplica la regla de que el
--       operario no ve importes.
-- ═══════════════════════════════════════════════════════════════════════════

do $$
declare t text;
begin
  foreach t in array array[
    'usuarios','cafes','formatos','articulos','precios','ubicaciones','clientes',
    'parametros','lotes','lote_composicion','operaciones','movimientos','saldos',
    'reservas','lote_activo','pedidos','pedido_lineas','eventos_entrada',
    'incidencias','mapeo_articulos'
  ] loop
    execute format('alter table %I enable row level security', t);
    execute format('alter table %I force row level security', t);
  end loop;
end $$;

-- Punto de partida: nadie toca nada. A partir de aquí solo se abre lo justo.
do $$
declare t text;
begin
  foreach t in array array[
    'usuarios','cafes','formatos','articulos','precios','ubicaciones','clientes',
    'parametros','lotes','lote_composicion','operaciones','movimientos','saldos',
    'reservas','lote_activo','pedidos','pedido_lineas','eventos_entrada',
    'incidencias','mapeo_articulos'
  ] loop
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;


/* ─────────────────────────── Lectura del catálogo ───────────────────────────
   Cualquiera identificado puede consultarlo: sin esto no se puede ni escanear.
   ──────────────────────────────────────────────────────────────── */

do $$
declare t text;
begin
  foreach t in array array[
    'cafes','formatos','articulos','ubicaciones','parametros','lotes',
    'lote_composicion','saldos','lote_activo','movimientos','operaciones',
    'reservas','clientes','mapeo_articulos'
  ] loop
    execute format('grant select on %I to authenticated', t);
    execute format($p$
      create policy %I on %I for select to authenticated
        using (app.tiene_nivel('OPERARIO'))
    $p$, 'leer_' || t, t);
  end loop;
end $$;


/* ─────────────────────────── Importes ───────────────────────────
   `precios` no tiene política para OPERARIO. No es que la aplicación oculte
   la columna: es que la consulta no devuelve la fila.
   ──────────────────────────────────────────────────────────────── */

grant select on precios to authenticated;
create policy leer_precios on precios
  for select to authenticated
  using (app.tiene_nivel('GESTOR'));

grant select on pedidos, pedido_lineas to authenticated;
create policy leer_pedidos on pedidos
  for select to authenticated
  using (app.tiene_nivel('GESTOR'));
create policy leer_pedido_lineas on pedido_lineas
  for select to authenticated
  using (app.tiene_nivel('GESTOR'));

-- El operario trabaja con las vistas sin importes, que no exponen las
-- columnas de dinero en ningún caso.
grant select on pedidos_operativo, pedido_lineas_operativo to authenticated;


/* ─────────────────────────── Usuarios ───────────────────────────
   Cada cual se ve a sí mismo; el administrador ve a todos. El hash del PIN
   no sale nunca por esta vía: la comprobación es app.pin_correcto(), que es
   SECURITY DEFINER y solo devuelve verdadero o falso.
   ──────────────────────────────────────────────────────────────── */

grant select on usuarios to authenticated;
create policy leer_usuarios on usuarios
  for select to authenticated
  using (usuario_id = app.usuario_actual() or app.tiene_nivel('ADMIN'));

grant insert, update on usuarios to authenticated;
create policy gestionar_usuarios on usuarios
  for all to authenticated
  using (app.tiene_nivel('ADMIN'))
  with check (app.tiene_nivel('ADMIN'));


/* ─────────────────────────── Mantenimiento del catálogo ───────────────────────────
   Dar de alta cafés, formatos, precios y clientes es cosa del gestor.
   ──────────────────────────────────────────────────────────────── */

do $$
declare t text;
begin
  foreach t in array array['cafes','formatos','articulos','precios','clientes',
                           'mapeo_articulos','ubicaciones'] loop
    execute format('grant insert, update, delete on %I to authenticated', t);
    execute format($p$
      create policy %I on %I for all to authenticated
        using (app.tiene_nivel('GESTOR')) with check (app.tiene_nivel('GESTOR'))
    $p$, 'gestionar_' || t, t);
  end loop;
end $$;

grant insert, update, delete on parametros to authenticated;
create policy gestionar_parametros on parametros
  for all to authenticated
  using (app.tiene_nivel('ADMIN')) with check (app.tiene_nivel('ADMIN'));


/* ─────────────────────────── Conciliación ─────────────────────────── */

grant select, update on incidencias to authenticated;
create policy leer_incidencias on incidencias
  for select to authenticated using (app.tiene_nivel('OPERARIO'));
create policy resolver_incidencias on incidencias
  for update to authenticated
  using (app.tiene_nivel('GESTOR')) with check (app.tiene_nivel('GESTOR'));

grant select, update on eventos_entrada to authenticated;
create policy leer_eventos on eventos_entrada
  for select to authenticated using (app.tiene_nivel('GESTOR'));
create policy reintentar_eventos on eventos_entrada
  for update to authenticated
  using (app.tiene_nivel('GESTOR')) with check (app.tiene_nivel('GESTOR'));


/* ═══════════════════════════════════════════════════════════════════════
   EL LIBRO NO SE ESCRIBE A MANO

   Ni `movimientos`, ni `operaciones`, ni `saldos`, ni `lote_activo` reciben
   GRANT de escritura. No hay política que valga: la única manera de anotar
   en el inventario es llamar a las funciones de dominio, que comprueban rol,
   idempotencia y disponibilidad antes de tocar nada.

   Es deliberado que esto no se pueda saltar "solo por esta vez".
   ═══════════════════════════════════════════════════════════════════════ */

revoke insert, update, delete on movimientos, operaciones, saldos,
                                  lote_activo, reservas, lotes, lote_composicion,
                                  pedidos, pedido_lineas
  from authenticated, anon;


/* ─────────────────────────── Funciones de dominio ─────────────────────────── */

grant execute on function
  registrar_recepcion_verde(uuid, text, numeric, text, text, date, numeric, uuid, timestamptz, text, text),
  registrar_tueste(uuid, jsonb, jsonb, text, uuid, timestamptz, text),
  registrar_traslado(uuid, text, text, text, numeric, uuid, timestamptz, text),
  registrar_venta(uuid, text, jsonb, text, uuid, text, text, text, text, text, uuid, timestamptz, uuid, text, boolean),
  registrar_movimiento(uuid, tipo_operacion, text, text, numeric, uuid, timestamptz, text),
  registrar_ajuste_inventario(uuid, text, jsonb, uuid, timestamptz, text),
  reservar_pedido(uuid, uuid, text, uuid, timestamptz),
  servir_reservas_pedido(uuid, uuid, uuid, timestamptz),
  liberar_reservas_pedido(uuid, uuid, uuid, timestamptz)
to authenticated;

grant execute on function
  app.tiene_nivel(text), app.rol_actual(), app.usuario_actual(),
  app.asignar_lotes(text, text, numeric), app.verificar_saldos(),
  app.parametro(text, text), app.parametro_int(text, int),
  app.ean13_valido(text)
to authenticated;

-- Reconstruir la proyección es una operación de mantenimiento.
revoke execute on function app.recalcular_saldos() from public, anon, authenticated;
