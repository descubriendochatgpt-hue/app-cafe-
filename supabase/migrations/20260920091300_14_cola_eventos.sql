-- ═══════════════════════════════════════════════════════════════════════════
--  14 · PROCESO DE LA COLA DE EVENTOS
--
--  La mecánica que comparten todos los conectores: tomar eventos sin que dos
--  procesos se pisen, marcarlos, y reintentar con espera creciente hasta
--  rendirse y pedir ayuda.
--
--  Vercel puede ejecutar dos veces la misma tarea programada, así que tomar
--  un evento tiene que ser atómico. De ahí el FOR UPDATE SKIP LOCKED.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function app.tomar_eventos(p_canal text, p_limite int default 25)
returns setof eventos_entrada
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return query
  with elegidos as (
    select evento_id
      from eventos_entrada
     where canal = p_canal
       and estado in ('PENDIENTE', 'FALLIDO')
       and intentos < 8
       and proximo_intento_en <= now()
     order by recibido_en
     limit p_limite
     -- Si otro proceso ya tiene este evento, se salta en vez de esperar:
     -- dos tareas solapadas reparten trabajo en lugar de duplicarlo.
     for update skip locked
  )
  update eventos_entrada e
     set intentos = e.intentos + 1,
         -- Se aparta ya: si el proceso muere a mitad, el evento no queda
         -- disponible al instante para entrar en un bucle.
         proximo_intento_en = now() + app.espera_reintento(e.intentos + 1)
    from elegidos
   where e.evento_id = elegidos.evento_id
  returning e.*;
end;
$$;

comment on function app.tomar_eventos(text, int) is
  'Reserva eventos para procesar. Incrementa el contador de intentos ANTES '
  'de procesar, para que un fallo que cuelgue el proceso no se repita sin fin.';

create or replace function app.evento_procesado(p_evento_id uuid, p_operacion_id uuid)
returns void
language sql
volatile
security definer
set search_path = public, pg_temp
as $$
  update eventos_entrada
     set estado = 'PROCESADO', procesado_en = now(),
         operacion_id = p_operacion_id, ultimo_error = null
   where evento_id = p_evento_id;
$$;

create or replace function app.evento_fallido(p_evento_id uuid, p_error text)
returns void
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_intentos int;
  v_canal    text;
  v_ref      text;
begin
  update eventos_entrada
     set estado = 'FALLIDO', ultimo_error = p_error
   where evento_id = p_evento_id
  returning intentos, canal, origen_id into v_intentos, v_canal, v_ref;

  -- Agotados los intentos, deja de ser un problema técnico y pasa a ser algo
  -- que alguien tiene que mirar. Aparece en la pantalla de conciliación.
  if v_intentos >= 8 and not exists (
       select 1 from incidencias
        where evento_id = p_evento_id and tipo = 'EVENTO_FALLIDO' and estado = 'ABIERTA') then
    perform app.abrir_incidencia('EVENTO_FALLIDO', v_canal, v_ref,
              jsonb_build_object('error', p_error, 'intentos', v_intentos),
              null, p_evento_id);
  end if;
end;
$$;

/** Vuelve a poner un evento en cola, por ejemplo después de mapear un SKU
    que faltaba. Reinicia los intentos: el motivo del fallo ya no existe. */
create or replace function reintentar_evento(p_evento_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para reintentar un evento.'
      using errcode = 'insufficient_privilege';
  end if;

  update eventos_entrada
     set estado = 'PENDIENTE', intentos = 0,
         proximo_intento_en = now(), ultimo_error = null
   where evento_id = p_evento_id and estado <> 'PROCESADO';

  update incidencias
     set estado = 'RESUELTA', resuelto_en = now(),
         resolucion = 'Reintentado tras corregir el mapeo'
   where evento_id = p_evento_id and estado = 'ABIERTA' and tipo = 'EVENTO_FALLIDO';

  return found;
end;
$$;


/* ─────────────────────────── Devoluciones ───────────────────────────
   Un reembolso en el TPV no es «una entrada cualquiera»: la mercancía vuelve
   a los MISMOS lotes de los que salió. Si no se hiciera así, devolver dos
   bolsas de un lote viejo las metería en el lote activo y la trazabilidad
   quedaría contando una historia que no ocurrió.
   ──────────────────────────────────────────────────────────────── */

create or replace function registrar_devolucion(
  p_operacion_id     uuid,
  p_ubicacion_id     text,
  p_lineas           jsonb,   -- [{"sku":…, "cantidad":…}]
  p_venta_origen_id  text default null,   -- origen_id de la venta que se devuelve
  p_origen           text default 'app',
  p_origen_id        text default null,
  p_usuario_id       uuid default null,
  p_ocurrido_en      timestamptz default now(),
  p_nota             text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_resto  numeric;
  v_toma   numeric;
  v_activo text;
  v_lotes  jsonb := '[]'::jsonb;
  l        record;
  m        record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para registrar una devolución.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'DEVOLUCION', p_origen, p_origen_id,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('lineas', p_lineas,
                                                'ubicacion_id', p_ubicacion_id,
                                                'venta_origen_id', p_venta_origen_id), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for l in select * from jsonb_to_recordset(p_lineas) as x(sku text, cantidad numeric)
  loop
    v_resto := l.cantidad;

    -- Primero, a los lotes de los que salió la venta original.
    if p_venta_origen_id is not null then
      for m in
        select mo.lote_id, -sum(mo.cantidad) as salieron
          from movimientos mo
          join operaciones o on o.operacion_id = mo.operacion_id
         where o.origen_id = p_venta_origen_id
           and o.tipo = 'VENTA'
           and mo.sku = l.sku
           and mo.ubicacion_id = p_ubicacion_id
           and mo.cantidad < 0
         group by mo.lote_id
         order by mo.lote_id
      loop
        exit when v_resto <= 0;
        v_toma := least(m.salieron, v_resto);
        perform app.anotar(p_operacion_id, m.lote_id, p_ubicacion_id, v_toma, p_ocurrido_en);
        v_lotes := v_lotes || jsonb_build_array(
          jsonb_build_object('lote_id', m.lote_id, 'cantidad', v_toma, 'de', 'venta original'));
        v_resto := v_resto - v_toma;
      end loop;
    end if;

    -- Lo que no se pueda casar con la venta original entra por el lote activo.
    if v_resto > 0 then
      select lote_id into v_activo
        from lote_activo where ubicacion_id = p_ubicacion_id and sku = l.sku;

      if v_activo is null then
        select s.lote_id into v_activo
          from saldos s join lotes lo on lo.lote_id = s.lote_id
         where s.ubicacion_id = p_ubicacion_id and s.sku = l.sku
         order by coalesce(lo.fecha_tostado, lo.fecha_recepcion, lo.creado_en::date) desc
         limit 1;
      end if;

      if v_activo is null then
        -- Nunca ha habido ese artículo aquí: no hay lote al que devolverlo.
        perform app.abrir_incidencia('LOTE_SIN_RESOLVER', p_origen,
          coalesce(p_origen_id, p_venta_origen_id),
          jsonb_build_object('sku', l.sku, 'ubicacion', p_ubicacion_id,
                             'cantidad', v_resto, 'motivo', 'devolución sin lote al que imputar'),
          p_operacion_id, null);
      else
        perform app.anotar(p_operacion_id, v_activo, p_ubicacion_id, v_resto, p_ocurrido_en);
        v_lotes := v_lotes || jsonb_build_array(
          jsonb_build_object('lote_id', v_activo, 'cantidad', v_resto, 'de', 'lote activo'));
      end if;
    end if;
  end loop;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'lotes', v_lotes);
end;
$$;

grant execute on function
  registrar_devolucion(uuid, text, jsonb, text, text, text, uuid, timestamptz, text),
  reintentar_evento(uuid)
to authenticated;


/* Abrir una incidencia desde la capa de aplicación. `app.abrir_incidencia` no
   se puede llamar por la API porque vive en el esquema interno, y los
   conectores necesitan poder decir «esto no lo sé resolver yo». */
create or replace function registrar_incidencia(
  p_tipo       text,
  p_canal      text default null,
  p_referencia text default null,
  p_detalle    jsonb default '{}'::jsonb,
  p_evento_id  uuid default null
) returns uuid
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para abrir una incidencia.'
      using errcode = 'insufficient_privilege';
  end if;
  return app.abrir_incidencia(p_tipo, p_canal, p_referencia, p_detalle, null, p_evento_id);
end;
$$;

/* Resolver una incidencia desde la pantalla de conciliación. */
create or replace function resolver_incidencia(p_incidencia_id uuid, p_resolucion text)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para resolver incidencias.'
      using errcode = 'insufficient_privilege';
  end if;

  update incidencias
     set estado = 'RESUELTA', resuelto_en = now(),
         resuelto_por = app.usuario_actual(), resolucion = p_resolucion
   where incidencia_id = p_incidencia_id and estado = 'ABIERTA';

  return found;
end;
$$;

grant execute on function
  registrar_incidencia(text, text, text, jsonb, uuid),
  resolver_incidencia(uuid, text)
to authenticated;


/* ─────────────────────────── Puerta de los conectores ───────────────────────────
   Los conectores no escriben en `eventos_entrada` directamente, igual que
   nadie escribe en `movimientos` directamente. Entran por estas funciones,
   que son las que comprueban el rol.

   Actúan con perfil SISTEMA: un JWT firmado por el servidor con rol SISTEMA,
   no con la clave de servicio. Así las mismas comprobaciones valen para una
   persona y para un webhook, y la clave que se salta RLS no circula.
   ──────────────────────────────────────────────────────────────── */

create or replace function recibir_evento(
  p_canal     text,
  p_tipo      text,
  p_origen_id text,
  p_payload   jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_id      uuid;
  v_nuevo   boolean := true;
  v_estado  estado_evento;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para registrar un evento.'
      using errcode = 'insufficient_privilege';
  end if;

  insert into eventos_entrada (canal, tipo, origen_id, payload)
  values (p_canal, p_tipo, p_origen_id, p_payload)
  on conflict (canal, origen_id, tipo) do nothing
  returning evento_id into v_id;

  -- Ya estaba: es un reenvío del webhook o un solape con la consulta
  -- periódica. No es un error, es el caso normal.
  if v_id is null then
    v_nuevo := false;
    select evento_id, estado into v_id, v_estado
      from eventos_entrada
     where canal = p_canal and origen_id = p_origen_id and tipo = p_tipo;
  end if;

  return jsonb_build_object('evento_id', v_id, 'nuevo', v_nuevo,
                            'estado', coalesce(v_estado::text, 'PENDIENTE'));
end;
$$;

create or replace function tomar_eventos(p_canal text, p_limite int default 25)
returns setof eventos_entrada
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para procesar la cola.'
      using errcode = 'insufficient_privilege';
  end if;
  return query select * from app.tomar_eventos(p_canal, p_limite);
end;
$$;

create or replace function evento_procesado(p_evento_id uuid, p_operacion_id uuid default null)
returns void
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor.' using errcode = 'insufficient_privilege';
  end if;
  perform app.evento_procesado(p_evento_id, p_operacion_id);
end;
$$;

create or replace function evento_fallido(p_evento_id uuid, p_error text)
returns void
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor.' using errcode = 'insufficient_privilege';
  end if;
  perform app.evento_fallido(p_evento_id, p_error);
end;
$$;

/* Marca de agua de la consulta periódica: hasta dónde se ha leído ya. */
create or replace function fijar_parametro(p_clave text, p_valor text)
returns void
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor.' using errcode = 'insufficient_privilege';
  end if;
  insert into parametros (clave, valor, descripcion)
  values (p_clave, p_valor, 'Fijado automáticamente por un conector')
  on conflict (clave) do update set valor = excluded.valor;
end;
$$;

grant execute on function
  recibir_evento(text, text, text, jsonb),
  tomar_eventos(text, int),
  evento_procesado(uuid, uuid),
  evento_fallido(uuid, text),
  fijar_parametro(text, text)
to authenticated;


/* Sonda de descuadre, accesible desde la aplicación. Debe devolver siempre
   cero filas: cualquier resultado es la proyección apartándose del libro.
   Si aparece alguno, deja constancia para que no dependa de que alguien
   estuviera mirando el resultado de la tarea en ese momento. */
create or replace function verificar_saldos_publico()
returns table (lote_id text, ubicacion_id text,
               segun_saldos numeric, segun_libro numeric, diferencia numeric)
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_n int;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor.' using errcode = 'insufficient_privilege';
  end if;

  return query select * from app.verificar_saldos();
  get diagnostics v_n = row_count;

  if v_n > 0 and not exists (
       select 1 from incidencias
        where tipo = 'DESCUADRE_SALDO' and estado = 'ABIERTA'
          and creado_en > now() - interval '1 day') then
    perform app.abrir_incidencia('DESCUADRE_SALDO', 'sistema', null,
              jsonb_build_object('lotes_afectados', v_n,
                                 'que_hacer', 'Ejecutar app.recalcular_saldos() y revisar el libro'));
  end if;
end;
$$;

grant execute on function verificar_saldos_publico() to authenticated;
