-- ═══════════════════════════════════════════════════════════════════════════
--  09 · REPRODUCCIÓN DEL HISTÓRICO
--
--  Vuelve a ejecutar una lista de operaciones sobre una base limpia llamando
--  a las MISMAS funciones de dominio que las registraron la primera vez.
--
--  No es solo un test: es la herramienta de recuperación. Si algún día hay
--  que reconstruir el inventario, se reproduce el histórico y tiene que salir
--  exactamente el mismo stock, lote a lote y ubicación a ubicación.
--
--  Las ventas NO guardan qué lote consumieron. Es deliberado: al reproducirlas
--  se vuelven a resolver con la política de la ubicación, y si el resultado
--  coincide es que la asignación es determinista de verdad. Lo mismo vale
--  para las devoluciones, que buscan los lotes de la venta que devuelven:
--  al reproducir en orden, esa venta ya está puesta.
--
--  `registrar_devolucion` y `registrar_pedido_canal` se definen más adelante
--  (migraciones 14 y 15). PL/pgSQL resuelve las llamadas al ejecutar, no al
--  crear, así que el orden de los ficheros no importa mientras todas se
--  apliquen. Este despachador se mantiene en un único sitio a propósito:
--  repartirlo entre migraciones haría que acabaran existiendo dos versiones.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function app.reproducir(p_operaciones jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  o            jsonb;
  v_datos      jsonb;
  v_tipo       tipo_operacion;
  v_id         uuid;
  v_usuario    uuid;
  v_cuando     timestamptz;
  v_pedido     uuid;
  v_hechas     int := 0;
  v_omitidas   int := 0;
begin
  if not app.tiene_nivel('ADMIN') then
    raise exception 'Reproducir el histórico es una operación de administrador.'
      using errcode = 'insufficient_privilege';
  end if;

  for o in select value from jsonb_array_elements(p_operaciones)
  loop
    v_id      := (o ->> 'operacion_id')::uuid;
    v_tipo    := (o ->> 'tipo')::tipo_operacion;
    v_usuario := nullif(o ->> 'usuario_id', '')::uuid;
    v_cuando  := (o ->> 'ocurrido_en')::timestamptz;
    v_datos   := coalesce(o -> 'datos', '{}'::jsonb);

    case v_tipo
      when 'RECEPCION_VERDE' then
        perform registrar_recepcion_verde(
          p_operacion_id    => v_id,
          p_sku             => v_datos ->> 'sku',
          p_cantidad_kg     => (v_datos ->> 'cantidad_kg')::numeric,
          p_ubicacion_id    => v_datos ->> 'ubicacion_id',
          p_proveedor       => v_datos ->> 'proveedor',
          p_fecha_recepcion => nullif(v_datos ->> 'fecha_recepcion', '')::date,
          p_precio_kg       => nullif(v_datos ->> 'precio_kg', '')::numeric,
          p_usuario_id      => v_usuario,
          p_ocurrido_en     => v_cuando,
          p_lote_id         => v_datos ->> 'lote_id',
          p_nota            => o ->> 'nota');

      when 'TUESTE' then
        perform registrar_tueste(
          p_operacion_id => v_id,
          p_consumos     => v_datos -> 'consumos',
          p_producciones => v_datos -> 'producciones',
          p_ubicacion_id => v_datos ->> 'ubicacion_id',
          p_usuario_id   => v_usuario,
          p_ocurrido_en  => v_cuando,
          p_nota         => o ->> 'nota');

      when 'TRASLADO' then
        perform registrar_traslado(
          p_operacion_id      => v_id,
          p_lote_id           => v_datos ->> 'lote_id',
          p_origen_ubicacion  => v_datos ->> 'de',
          p_destino_ubicacion => v_datos ->> 'a',
          p_cantidad          => (v_datos ->> 'cantidad')::numeric,
          p_usuario_id        => v_usuario,
          p_ocurrido_en       => v_cuando,
          p_nota              => o ->> 'nota');

      when 'RESERVA' then
        -- La reserva de un canal trae sus líneas y se puede rehacer entera.
        -- La de un pedido creado a mano no: ese pedido no nació de ninguna
        -- operación reproducible.
        if v_datos ? 'lineas' then
          perform registrar_pedido_canal(
            p_operacion_id => v_id,
            p_ubicacion_id => v_datos ->> 'ubicacion_id',
            p_lineas       => v_datos -> 'lineas',
            p_canal        => coalesce(v_datos ->> 'canal', 'Online'),
            p_origen       => coalesce(o ->> 'origen', 'app'),
            p_origen_id    => o ->> 'origen_id',
            p_cliente_id   => nullif(v_datos ->> 'cliente_id', '')::uuid,
            p_documento_fiscal         => v_datos ->> 'documento_fiscal',
            p_documento_fiscal_sistema => v_datos ->> 'documento_fiscal_sistema',
            p_forma_pago   => v_datos ->> 'forma_pago',
            p_ocurrido_en  => v_cuando,
            p_nota         => o ->> 'nota');
        else
          v_omitidas := v_omitidas + 1;
          continue;
        end if;

      when 'LIBERACION' then
        v_pedido := (pedido_de_canal(v_datos ->> 'pedido_origen',
                                     v_datos ->> 'pedido_origen_id') ->> 'pedido_id')::uuid;
        if v_pedido is null then
          v_omitidas := v_omitidas + 1;
          continue;
        end if;
        perform liberar_reservas_pedido(v_id, v_pedido, v_usuario, v_cuando);

      when 'VENTA' then
        -- Servir un pedido reservado no es una venta desde cero: hay que
        -- encontrar el pedido que se reprodujo antes. Se busca por el
        -- identificador del canal, porque los uuid internos son otros.
        if v_datos ->> 'desde' = 'reservas' then
          v_pedido := (pedido_de_canal(v_datos ->> 'pedido_origen',
                                       v_datos ->> 'pedido_origen_id') ->> 'pedido_id')::uuid;
          if v_pedido is null then
            v_omitidas := v_omitidas + 1;
            continue;
          end if;
          perform servir_reservas_pedido(
            v_id, v_pedido, v_usuario, v_cuando,
            coalesce(o ->> 'origen', 'app'), o ->> 'origen_id');
        else
          perform registrar_venta(
            p_operacion_id => v_id,
            p_ubicacion_id => v_datos ->> 'ubicacion_id',
            p_lineas       => v_datos -> 'lineas',
            p_canal        => coalesce(v_datos ->> 'canal', 'Mostrador'),
            p_cliente_id   => nullif(v_datos ->> 'cliente_id', '')::uuid,
            p_origen       => coalesce(o ->> 'origen', 'app'),
            p_origen_id    => o ->> 'origen_id',
            p_documento_fiscal         => v_datos ->> 'documento_fiscal',
            p_documento_fiscal_sistema => v_datos ->> 'documento_fiscal_sistema',
            p_forma_pago   => v_datos ->> 'forma_pago',
            p_usuario_id   => v_usuario,
            p_ocurrido_en  => v_cuando,
            p_nota         => o ->> 'nota');
        end if;

      when 'DEVOLUCION' then
        -- Hay dos formas de devolución y no se reproducen igual:
        --   · la de un canal (un reembolso en el TPV) llega con líneas por
        --     SKU y tiene que volver a los lotes de la venta original;
        --   · la manual es un movimiento suelto sobre un lote concreto.
        -- Se distinguen por la carga, no por el tipo.
        if v_datos ? 'lineas' then
          perform registrar_devolucion(
            p_operacion_id    => v_id,
            p_ubicacion_id    => v_datos ->> 'ubicacion_id',
            p_lineas          => v_datos -> 'lineas',
            p_venta_origen_id => v_datos ->> 'venta_origen_id',
            p_origen          => coalesce(o ->> 'origen', 'app'),
            p_origen_id       => o ->> 'origen_id',
            p_usuario_id      => v_usuario,
            p_ocurrido_en     => v_cuando,
            p_nota            => o ->> 'nota');
        else
          perform registrar_movimiento(
            p_operacion_id => v_id,
            p_tipo         => v_tipo,
            p_lote_id      => v_datos ->> 'lote_id',
            p_ubicacion_id => v_datos ->> 'ubicacion',
            p_cantidad     => (v_datos ->> 'cantidad')::numeric,
            p_usuario_id   => v_usuario,
            p_ocurrido_en  => v_cuando,
            p_nota         => o ->> 'nota');
        end if;

      when 'ENTRADA', 'SALIDA', 'MERMA' then
        perform registrar_movimiento(
          p_operacion_id => v_id,
          p_tipo         => v_tipo,
          p_lote_id      => v_datos ->> 'lote_id',
          p_ubicacion_id => v_datos ->> 'ubicacion',
          p_cantidad     => (v_datos ->> 'cantidad')::numeric,
          p_usuario_id   => v_usuario,
          p_ocurrido_en  => v_cuando,
          p_nota         => o ->> 'nota');

      when 'AJUSTE' then
        perform registrar_ajuste_inventario(
          p_operacion_id => v_id,
          p_ubicacion_id => v_datos ->> 'ubicacion',
          p_recuento     => v_datos -> 'recuento',
          p_usuario_id   => v_usuario,
          p_ocurrido_en  => v_cuando,
          p_nota         => o ->> 'nota');

      else
        v_omitidas := v_omitidas + 1;
        continue;
    end case;

    v_hechas := v_hechas + 1;
  end loop;

  return jsonb_build_object('reproducidas', v_hechas, 'omitidas', v_omitidas);
end;
$$;

comment on function app.reproducir(jsonb) is
  'Reejecuta el histórico llamando a las funciones de dominio reales. '
  'Con el mismo catálogo de partida debe producir el mismo stock final.';

-- Exporta el histórico en el orden en que ocurrió, listo para reproducir.
create or replace function app.exportar_historico()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(x order by x_ocurrido, x_registrado), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'operacion_id', operacion_id,
               'tipo',         tipo,
               'origen',       origen,
               'origen_id',    origen_id,
               'usuario_id',   usuario_id,
               'ocurrido_en',  ocurrido_en,
               'datos',        datos,
               'nota',         nota) as x,
             ocurrido_en   as x_ocurrido,
             registrado_en as x_registrado
        from operaciones
    ) z;
$$;
