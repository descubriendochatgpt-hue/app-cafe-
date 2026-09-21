-- ═══════════════════════════════════════════════════════════════════════════
--  01 · FUNDACIONES
--  Extensiones, esquema de utilidades, tipos del dominio y contexto de sesión.
-- ═══════════════════════════════════════════════════════════════════════════

/* ─────────────────────── pgcrypto, y dónde vive ───────────────────────
   El PIN se guarda con bcrypt, que lo pone pgcrypto. Dónde acaba instalada
   esa extensión NO es igual en todas partes:

     · en un Postgres limpio cae en `public`;
     · en Supabase ya viene puesta, y vive en `extensions`.

   Y eso importa porque las funciones que comprueban el PIN son SECURITY
   DEFINER y fijan su `search_path` —tienen que hacerlo: si no lo fijaran,
   quien las llama podría anteponer un esquema con su propio `crypt()` y
   hacer que cualquier PIN valga—. Al fijarlo, si el esquema donde está
   pgcrypto no aparece en esa lista, `crypt` sencillamente no existe para
   ellas. En Supabase eso salía como «function crypt(text, text) does not
   exist» doscientas líneas más abajo, que no dice nada de la causa.

   Por eso se nombra `extensions` explícitamente en el search_path de esas
   funciones, y por eso aquí se asegura que el esquema existe.             */

create schema if not exists extensions;
grant usage on schema extensions to anon, authenticated, service_role;
create extension if not exists pgcrypto with schema extensions;

-- Si alguien la instaló en un tercer sitio, más vale decirlo aquí y con
-- nombre y apellidos que dejar que falle luego donde no se entiende.
do $$
declare v_esquema text;
begin
  select n.nspname into v_esquema
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';

  if v_esquema is null then
    raise exception 'No se pudo instalar pgcrypto, y sin ella no hay PIN que valga.';
  end if;

  if v_esquema not in ('public', 'extensions') then
    raise exception
      'pgcrypto está instalada en el esquema «%», y las funciones del PIN solo '
      'miran en «public» y «extensions». Muévela con: ALTER EXTENSION pgcrypto '
      'SET SCHEMA extensions;', v_esquema;
  end if;
end $$;

-- Supabase ya trae estos roles. En un Postgres limpio (tests locales, CI) no,
-- así que se crean solo si faltan: la misma migración vale en los dos sitios.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

create schema if not exists app;
comment on schema app is
  'Utilidades internas: contexto de sesión y funciones de apoyo. No expone datos.';

grant usage on schema app to anon, authenticated, service_role;


/* ─────────────────────────────────────────────────────────────────────────
   CONTEXTO DE SESIÓN

   En Supabase, PostgREST publica los claims del JWT en `request.jwt.claims`.
   En un Postgres suelto eso no existe, así que las funciones caen a unos GUC
   (`app.usuario_id`, `app.rol`) que los tests fijan con set_config().

   Gracias a eso las MISMAS políticas RLS se ejecutan en producción y en los
   tests, sin ramas ni dobles de prueba: lo que se verifica es lo que corre.
   ───────────────────────────────────────────────────────────────────────── */

create or replace function app.claims()
returns jsonb
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  );
$$;

create or replace function app.usuario_actual()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(app.claims() ->> 'sub', ''),
    nullif(current_setting('app.usuario_id', true), '')
  )::uuid;
$$;

create or replace function app.rol_actual()
returns text
language sql
stable
as $$
  select upper(coalesce(
    nullif(app.claims() ->> 'rol', ''),
    nullif(current_setting('app.rol', true), ''),
    'ANONIMO'
  ));
$$;

-- Jerarquía de permisos: OPERARIO(1) < GESTOR(2) < ADMIN(3).
-- SISTEMA(4) es el actor de los conectores automáticos (webhooks, cron).
create or replace function app.nivel(p_rol text)
returns int
language sql
immutable
as $$
  select case upper(coalesce(p_rol, ''))
           when 'OPERARIO' then 1
           when 'GESTOR'   then 2
           when 'ADMIN'    then 3
           when 'SISTEMA'  then 4
           else 0
         end;
$$;

create or replace function app.tiene_nivel(p_minimo text)
returns boolean
language sql
stable
as $$
  select app.nivel(app.rol_actual()) >= app.nivel(p_minimo);
$$;

comment on function app.tiene_nivel(text) is
  'Cierto si el rol de la sesión alcanza el nivel pedido. Base de todas las RLS.';


/* ─────────────────────────────────────────────────────────────────────────
   TIPOS DEL DOMINIO
   ───────────────────────────────────────────────────────────────────────── */

create type rol_usuario as enum ('OPERARIO', 'GESTOR', 'ADMIN');

-- Unidad en que se lleva el artículo en el libro de movimientos.
--   KG → café verde y tostado a granel (admite decimales)
--   UD → paquetes terminados (siempre entero)
create type unidad_medida as enum ('KG', 'UD');

-- VERDE    → saco de importación, se compra
-- GRANEL   → tostado sin envasar; opcional, solo si se separa tueste de envasado
-- PAQUETE  → producto terminado con su formato, es lo que se vende
create type clase_articulo as enum ('VERDE', 'GRANEL', 'PAQUETE');

create type molienda as enum ('GRANO', 'MOLIDO');

-- PROPIA   → almacén, tienda, furgoneta: mercancía en nuestras manos
-- DEPOSITO → depósito El Corte Inglés: nuestra propiedad, en casa ajena
-- TRANSITO → mercancía en reparto
create type tipo_ubicacion as enum ('PROPIA', 'DEPOSITO', 'TRANSITO');

-- Cómo se decide de qué lote sale la mercancía cuando nadie escanea:
--   LOTE_ACTIVO → el lote repuesto en esa ubicación (tienda, furgoneta)
--   FIFO        → el más antiguo con saldo (depósito ECI: no lo vemos)
create type politica_lote as enum ('LOTE_ACTIVO', 'FIFO');

create type tipo_operacion as enum (
  'RECEPCION_VERDE',   -- entra un saco de café verde comprado
  'TUESTE',            -- transformación: consume verde, produce paquetes
  'TRASLADO',          -- movimiento entre ubicaciones (incluye servir a ECI)
  'VENTA',             -- salida definitiva por venta
  'DEVOLUCION',        -- entrada por devolución de cliente o de depósito
  'ENTRADA',           -- entrada manual sin origen comercial
  'SALIDA',            -- salida manual: muestras, autoconsumo
  'MERMA',             -- pérdida: rotura, caducidad
  'AJUSTE',            -- corrección por recuento físico
  'RESERVA',           -- compromete stock sin sacarlo del libro
  'LIBERACION'         -- deshace una reserva
);

create type estado_reserva as enum ('ACTIVA', 'SERVIDA', 'LIBERADA');

create type estado_pedido as enum (
  'BORRADOR', 'CONFIRMADO', 'PREPARANDO', 'SERVIDO', 'ENTREGADO', 'CANCELADO'
);

create type estado_evento as enum ('PENDIENTE', 'PROCESADO', 'FALLIDO', 'DESCARTADO');

create type estado_incidencia as enum ('ABIERTA', 'RESUELTA', 'DESCARTADA');
