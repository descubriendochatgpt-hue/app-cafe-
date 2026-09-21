-- ═══════════════════════════════════════════════════════════════════
--  ESQUEMA COMPLETO · generado por generar-esquema.sh, no editar
--
--  Pégalo entero en Supabase → SQL Editor y dale a Run. Crea las
--  tablas, las políticas RLS, las funciones y un administrador con
--  PIN 1234 que hay que cambiar antes de usarlo de verdad.
--
--  Se puede volver a ejecutar sobre una base ya creada: fallará al
--  llegar a la primera tabla que ya exista, y no habrá tocado nada,
--  porque el editor de Supabase lo ejecuta todo en una transacción.
-- ═══════════════════════════════════════════════════════════════════


-- ╔══ 20260920090000_01_fundaciones.sql ══╗

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

-- ╔══ 20260920090100_02_catalogo.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  02 · CATÁLOGO
--  Quién trabaja, qué se vende, en qué formatos y desde qué ubicaciones.
--  Nada de aquí es un hecho contable: son los maestros que el ledger referencia.
-- ═══════════════════════════════════════════════════════════════════════════

/* ─────────────────────────── Usuarios ─────────────────────────── */

create table usuarios (
  usuario_id  uuid primary key default gen_random_uuid(),
  nombre      text        not null check (length(btrim(nombre)) between 2 and 80),
  pin_hash    text        not null,
  rol         rol_usuario not null default 'OPERARIO',
  activo      boolean     not null default true,
  creado_en   timestamptz not null default now()
);

comment on table usuarios is
  'El PIN nunca se guarda en claro: pin_hash es bcrypt (pgcrypto). '
  'La comprobación vive en el servidor, que después firma el JWT de la sesión.';

create unique index usuarios_nombre_unico on usuarios (lower(nombre));
create index usuarios_activos on usuarios (activo) where activo;

create or replace function app.hash_pin(p_pin text)
returns text
language sql
volatile
-- `extensions` porque ahí vive pgcrypto en Supabase. Ver migración 01.
set search_path = public, extensions, pg_temp
as $$
  select crypt(p_pin, gen_salt('bf', 10));
$$;

create or replace function app.pin_correcto(p_usuario_id uuid, p_pin text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from usuarios
     where usuario_id = p_usuario_id
       and activo
       and pin_hash = crypt(p_pin, pin_hash)
  );
$$;


/* ─────────────────────────── Cafés y formatos ─────────────────────────── */

create table cafes (
  cafe_id       text primary key check (cafe_id ~ '^[A-Z0-9]{2,10}$'),
  nombre        text not null,
  origen        text,
  variedad      text,
  proceso       text,
  altitud       text,
  perfil_tueste text,
  notas_cata    text,
  activo        boolean     not null default true,
  creado_en     timestamptz not null default now()
);

comment on column cafes.cafe_id is
  'Código corto que viaja dentro del QR de la etiqueta. Cambiarlo invalida '
  'las etiquetas ya impresas, así que es inmutable en la práctica.';

create table formatos (
  formato_id text primary key check (formato_id ~ '^[A-Z0-9]{1,8}$'),
  nombre     text     not null,
  gramos     integer  not null check (gramos > 0 and gramos <= 25000),
  molienda   molienda not null default 'GRANO',
  activo     boolean  not null default true
);

comment on column formatos.gramos is
  'Peso neto real. Se usa para el cálculo de merma del tueste y el peso de los bultos.';


/* ─────────────────────────── Artículos ───────────────────────────
   El SKU es la unidad que el libro de movimientos mueve. Un café verde,
   un tostado a granel y cada formato empaquetado son artículos distintos:
   así el tueste puede expresarse como una transformación entre SKU.
   ──────────────────────────────────────────────────────────────── */

create table articulos (
  sku        text primary key check (sku ~ '^[A-Z0-9][A-Z0-9-]{1,39}$'),
  clase      clase_articulo not null,
  cafe_id    text not null references cafes (cafe_id) on update cascade,
  formato_id text references formatos (formato_id) on update cascade,
  unidad     unidad_medida  not null,
  ean13      text,
  activo     boolean     not null default true,
  creado_en  timestamptz not null default now(),

  -- Un paquete necesita formato y se cuenta en unidades enteras.
  -- El verde y el granel se llevan en kilos y no tienen formato.
  constraint articulo_coherente check (
    (clase = 'PAQUETE' and formato_id is not null and unidad = 'UD') or
    (clase in ('VERDE', 'GRANEL') and formato_id is null and unidad = 'KG')
  ),
  -- El EAN identifica un producto de venta, no un lote ni un saco.
  constraint ean_solo_en_paquetes check (ean13 is null or clase = 'PAQUETE')
);

create unique index articulos_cafe_formato
  on articulos (cafe_id, formato_id)
  where clase = 'PAQUETE';

create unique index articulos_ean_unico on articulos (ean13) where ean13 is not null;
create index articulos_por_cafe on articulos (cafe_id);

-- Dígito de control de un EAN-13. Se valida en la base de datos para que no
-- entre un código mal copiado por ninguna vía: ni por la app, ni por un script.
create or replace function app.ean13_valido(p_codigo text)
returns boolean
language plpgsql
immutable
as $$
declare
  v_suma int := 0;
  v_i    int;
  v_d    int;
begin
  if p_codigo is null then return true; end if;
  if p_codigo !~ '^[0-9]{13}$' then return false; end if;

  for v_i in 1..12 loop
    v_d := substr(p_codigo, v_i, 1)::int;
    v_suma := v_suma + v_d * case when v_i % 2 = 0 then 3 else 1 end;
  end loop;

  return ((10 - (v_suma % 10)) % 10) = substr(p_codigo, 13, 1)::int;
end;
$$;

alter table articulos
  add constraint ean13_bien_formado check (app.ean13_valido(ean13));


/* ─────────────────────────── Precios y costes ───────────────────────────
   Tabla aparte, y no columnas de `articulos`, por una razón de seguridad:
   el operario no debe ver importes. Separarlo convierte un permiso por
   columna (que RLS no sabe expresar) en un permiso por tabla, que sí.
   ──────────────────────────────────────────────────────────────── */

create table precios (
  sku             text primary key references articulos (sku) on update cascade,
  precio_venta    numeric(12,4) check (precio_venta    >= 0),
  coste_unitario  numeric(12,4) check (coste_unitario  >= 0),
  stock_minimo    numeric(12,3) check (stock_minimo    >= 0),
  stock_objetivo  numeric(12,3) check (stock_objetivo  >= 0),
  actualizado_en  timestamptz not null default now()
);

comment on table precios is
  'Separada de articulos a propósito: el rol OPERARIO no tiene política de '
  'lectura sobre esta tabla, así que el servidor no puede filtrarla por error.';


/* ─────────────────────────── Ubicaciones ─────────────────────────── */

create table ubicaciones (
  ubicacion_id   text primary key check (ubicacion_id ~ '^[A-Z0-9_]{2,24}$'),
  nombre         text           not null,
  tipo           tipo_ubicacion not null default 'PROPIA',
  politica_lote  politica_lote  not null default 'LOTE_ACTIVO',
  permite_venta  boolean        not null default true,
  activo         boolean        not null default true,
  notas          text
);

comment on column ubicaciones.politica_lote is
  'LOTE_ACTIVO: consume el lote repuesto por el último escaneo de entrada. '
  'FIFO: consume el más antiguo con saldo. El depósito de ECI es FIFO por '
  'fuerza: sus tiendas mezclan lotes y reportan ventas agregadas.';

comment on column ubicaciones.tipo is
  'DEPOSITO marca mercancía que sigue siendo nuestra aunque esté en casa '
  'ajena. Servir ahí es un traslado, nunca una venta.';


/* ─────────────────────────── Clientes ─────────────────────────── */

create table clientes (
  cliente_id     uuid primary key default gen_random_uuid(),
  nombre         text not null,
  tipo           text not null default 'Particular',
  nif            text,
  email          text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  telefono       text,
  direccion      text,
  cp             text,
  poblacion      text,
  provincia      text,
  pais           text not null default 'España',
  descuento_pct  numeric(5,2) not null default 0 check (descuento_pct between 0 and 100),
  alta           date,
  activo         boolean     not null default true,
  notas          text,
  creado_en      timestamptz not null default now()
);

create index clientes_nombre on clientes using gin (to_tsvector('spanish', nombre));
create unique index clientes_nif_unico on clientes (upper(nif)) where nif is not null;


/* ─────────────────────────── Parámetros ───────────────────────────
   Todo lo configurable vive aquí y no en el código: umbrales de frescura,
   días de consumo preferente, merma esperada. Cambiarlos no es un despliegue.
   ──────────────────────────────────────────────────────────────── */

create table parametros (
  clave       text primary key check (clave ~ '^[a-z0-9_]{3,40}$'),
  valor       text not null,
  descripcion text not null
);

create or replace function app.parametro(p_clave text, p_defecto text default null)
returns text
language sql
stable
as $$
  select coalesce((select valor from parametros where clave = p_clave), p_defecto);
$$;

create or replace function app.parametro_int(p_clave text, p_defecto int)
returns int
language sql
stable
as $$
  select coalesce(nullif(app.parametro(p_clave), '')::int, p_defecto);
$$;

insert into parametros (clave, valor, descripcion) values
  ('dias_consumo_preferente', '365', 'Días desde el tueste hasta el consumo preferente impreso en la etiqueta'),
  ('dias_frescura_aviso',      '45', 'A partir de estos días desde el tueste el lote se marca en ámbar'),
  ('dias_frescura_critico',    '90', 'A partir de estos días el lote se marca en rojo y no debería servirse'),
  ('dias_cobertura_aviso',     '21', 'Aviso si al ritmo de venta actual queda menos stock que estos días'),
  ('dias_venta_media',         '90', 'Ventana usada para calcular la velocidad de venta de cada referencia'),
  ('merma_tueste_min_pct',     '10', 'Merma por debajo de la cual el tueste se considera sospechoso'),
  ('merma_tueste_max_pct',     '22', 'Merma por encima de la cual el tueste se considera sospechoso'),
  ('iva_por_defecto',          '21', 'IVA aplicado cuando el canal no informa de otro'),
  ('dias_antiguedad_deposito', '90', 'A partir de estos días en depósito, la mercancía entra en el informe de antigüedad');

-- ╔══ 20260920090200_03_ledger.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  03 · EL LIBRO DE MOVIMIENTOS
--
--  Regla única de la que depende todo lo demás:
--    el stock NO se guarda, se deriva. `movimientos` es un libro que solo
--    admite inserciones; `saldos` es una proyección que mantiene un disparador
--    y que nadie escribe a mano. Si las dos discrepan, manda el libro.
--
--  `saldos` existe por una razón concreta y no por comodidad: es la fila que
--  se bloquea para serializar dos ventas simultáneas del mismo lote. Sumar el
--  libro entero en cada venta no daría esa garantía sin bloquear la tabla.
-- ═══════════════════════════════════════════════════════════════════════════

/* ─────────────────────────── Lotes ─────────────────────────── */

create table lotes (
  lote_id      text primary key check (length(lote_id) between 4 and 64),
  sku          text not null references articulos (sku) on update cascade,

  -- Café verde
  proveedor        text,
  fecha_recepcion  date,
  precio_kg        numeric(12,4) check (precio_kg >= 0),

  -- Tostado y empaquetado
  fecha_tostado             date,
  fecha_consumo_preferente  date,

  notas      text,
  creado_por uuid references usuarios (usuario_id),
  creado_en  timestamptz not null default now(),

  constraint consumo_posterior_al_tueste
    check (fecha_consumo_preferente is null
           or fecha_tostado is null
           or fecha_consumo_preferente >= fecha_tostado)
);

comment on table lotes is
  'Unidad de trazabilidad. El identificador es legible y lleva la fecha de '
  'tueste dentro (CAF-ETHYIR-250-260814-A): aunque se pierda la base de datos, '
  'la bolsa sigue diciendo qué es y cuándo se tostó.';

create index lotes_por_sku on lotes (sku);
create index lotes_por_tueste on lotes (fecha_tostado);

-- Un tueste puede mezclar varios sacos de verde (la "Mezcla Casa" son dos
-- orígenes), así que la ascendencia de un lote es una relación, no una columna.
create table lote_composicion (
  lote_hijo_id  text not null references lotes (lote_id) on delete restrict,
  lote_padre_id text not null references lotes (lote_id) on delete restrict,
  cantidad      numeric(14,3) not null check (cantidad > 0),
  primary key (lote_hijo_id, lote_padre_id),
  constraint sin_autorreferencia check (lote_hijo_id <> lote_padre_id)
);

comment on table lote_composicion is
  'Ascendencia del lote: de qué sacos de verde y en qué cantidad salió. '
  'Recorrerla hacia arriba da la trazabilidad desde la venta hasta la importación.';

create index composicion_por_padre on lote_composicion (lote_padre_id);


/* ─────────────────────────── Operaciones ───────────────────────────
   Toda escritura en el libro pertenece a una operación. La operación es la
   unidad de idempotencia, y tiene dos claves para las dos formas de repetición
   que se dan en la práctica:

     · operacion_id  → la PWA offline genera el UUID antes de guardar en su
                       cola local; si sube la misma operación dos veces (mala
                       cobertura, reintento, usuario impaciente), la segunda
                       choca contra la clave primaria.
     · (origen, origen_id) → Loyverse y WooCommerce reenvían webhooks. El id
                       del recibo o del pedido llega siempre igual, así que
                       un reenvío choca contra el índice único.
   ──────────────────────────────────────────────────────────────── */

create table operaciones (
  operacion_id  uuid primary key,
  tipo          tipo_operacion not null,
  origen        text not null default 'app'
                  check (origen in ('app','loyverse','woocommerce','eci','importacion','sistema')),
  origen_id     text,
  usuario_id    uuid references usuarios (usuario_id),
  ocurrido_en   timestamptz not null,
  registrado_en timestamptz not null default now(),
  datos         jsonb not null default '{}'::jsonb,
  nota          text
);

comment on column operaciones.ocurrido_en is
  'Cuándo pasó de verdad. En una venta encolada sin cobertura es la hora del '
  'móvil, no la de llegada al servidor. Los informes usan esta columna.';
comment on column operaciones.registrado_en is
  'Cuándo llegó a la base de datos. La distancia con ocurrido_en mide el '
  'retraso de cada canal.';
comment on column operaciones.datos is
  'Carga original tal cual llegó (recibo de Loyverse, pedido de Woo). Permite '
  'reprocesar el histórico sin volver a pedir nada a los sistemas externos.';

create unique index operaciones_origen_unico
  on operaciones (origen, origen_id)
  where origen_id is not null;

create index operaciones_por_fecha on operaciones (ocurrido_en desc);
create index operaciones_por_tipo on operaciones (tipo, ocurrido_en desc);


/* ─────────────────────────── Movimientos ─────────────────────────── */

create table movimientos (
  movimiento_id bigint generated always as identity primary key,
  operacion_id  uuid not null references operaciones (operacion_id),
  sku           text not null references articulos (sku) on update cascade,
  lote_id       text not null references lotes (lote_id),
  ubicacion_id  text not null references ubicaciones (ubicacion_id) on update cascade,

  -- Con signo: negativo sale, positivo entra. Un traslado son dos filas con
  -- la misma operacion_id, y por eso siempre suma cero en el conjunto.
  cantidad      numeric(14,3) not null check (cantidad <> 0),

  ocurrido_en   timestamptz not null,
  registrado_en timestamptz not null default now()
);

comment on table movimientos is
  'Libro inmutable. Solo admite INSERT: hay disparadores que rechazan UPDATE, '
  'DELETE y TRUNCATE. Una corrección es un movimiento nuevo de tipo AJUSTE, '
  'nunca la edición del anterior.';

create index movimientos_saldo on movimientos (lote_id, ubicacion_id);
create index movimientos_por_operacion on movimientos (operacion_id);
create index movimientos_por_sku on movimientos (sku, ocurrido_en desc);
create index movimientos_por_ubicacion on movimientos (ubicacion_id, ocurrido_en desc);


/* ── Inmutabilidad ──
   Sin esto, "libro append-only" es una convención que alguien romperá con un
   UPDATE a las nueve de la noche. Con esto, es una propiedad de la base. */

create or replace function app.libro_inmutable()
returns trigger
language plpgsql
as $$
begin
  raise exception
    'El libro de movimientos es inmutable: % no está permitido sobre %. '
    'Para corregir, registra un movimiento de AJUSTE.',
    tg_op, tg_table_name
    using errcode = 'restrict_violation';
end;
$$;

create trigger movimientos_sin_update
  before update on movimientos
  for each row execute function app.libro_inmutable();

create trigger movimientos_sin_delete
  before delete on movimientos
  for each row execute function app.libro_inmutable();

create trigger movimientos_sin_truncate
  before truncate on movimientos
  for each statement execute function app.libro_inmutable();


/* ─────────────────────────── Saldos ─────────────────────────── */

create table saldos (
  lote_id      text not null references lotes (lote_id),
  ubicacion_id text not null references ubicaciones (ubicacion_id) on update cascade,
  sku          text not null references articulos (sku) on update cascade,

  cantidad   numeric(14,3) not null default 0,
  reservado  numeric(14,3) not null default 0,
  disponible numeric(14,3) generated always as (cantidad - reservado) stored,

  actualizado_en timestamptz not null default now(),

  primary key (lote_id, ubicacion_id),

  -- La garantía de que dos ventas simultáneas del último paquete no dejan
  -- el stock en negativo. No es una comprobación de la aplicación que se
  -- pueda olvidar: es una restricción de la base sobre la fila bloqueada.
  constraint saldo_nunca_negativo check (cantidad >= 0),
  constraint reservado_coherente  check (reservado >= 0 and reservado <= cantidad)
  -- Nota: cuando `cantidad` baja de cero saltan las dos restricciones a la
  -- vez y Postgres no garantiza cuál informa. Por eso app.anotar() trata
  -- las dos como el mismo caso: no hay stock.
);

comment on table saldos is
  'Proyección derivada del libro. La mantiene un disparador y ninguna otra '
  'cosa: app.recalcular_saldos() la reconstruye desde cero y debe dar siempre '
  'el mismo resultado. Si no lo da, hay un fallo y app.verificar_saldos() lo localiza.';

create index saldos_por_sku on saldos (sku, ubicacion_id);
create index saldos_con_existencias on saldos (ubicacion_id, sku) where cantidad > 0;

revoke insert, update, delete on saldos from public;

create or replace function app.proyectar_saldo()
returns trigger
language plpgsql
as $$
begin
  -- Primero el UPDATE, y no un INSERT ... ON CONFLICT DO UPDATE.
  --
  -- La diferencia no es de estilo: con ON CONFLICT, Postgres evalúa las
  -- restricciones CHECK sobre la fila PROPUESTA antes de resolver el
  -- conflicto. Una salida de 20 sobre un saldo de 60 propondría la fila
  -- (cantidad = -20) y saltaría saldo_nunca_negativo, aunque el resultado
  -- correcto fuese 40. Es decir: ningún movimiento negativo funcionaría.
  --
  -- El UPDATE además toma el bloqueo de la fila, que es donde se serializan
  -- dos ventas simultáneas del mismo lote: la segunda espera, vuelve a leer
  -- el valor ya confirmado y es entonces cuando la restricción decide.
  update saldos
     set cantidad       = cantidad + new.cantidad,
         actualizado_en = now()
   where lote_id = new.lote_id
     and ubicacion_id = new.ubicacion_id;

  if not found then
    if new.cantidad < 0 then
      raise exception 'No hay stock del lote % en %: no existe saldo del que restar.',
        new.lote_id, new.ubicacion_id
        using errcode = 'check_violation', hint = 'stock_insuficiente';
    end if;

    -- Primera entrada de este lote en esta ubicación. El ON CONFLICT de aquí
    -- sí es seguro: la fila propuesta es positiva y no viola ningún CHECK.
    insert into saldos (lote_id, ubicacion_id, sku, cantidad, actualizado_en)
    values (new.lote_id, new.ubicacion_id, new.sku, new.cantidad, now())
    on conflict (lote_id, ubicacion_id) do update
      set cantidad       = saldos.cantidad + excluded.cantidad,
          actualizado_en = now();
  end if;

  return new;
end;
$$;

comment on function app.proyectar_saldo() is
  'Mantiene la proyección de saldos. El UPDATE previo bloquea la fila y es '
  'donde se serializan las ventas concurrentes del mismo lote.';

create trigger movimientos_proyectan_saldo
  after insert on movimientos
  for each row execute function app.proyectar_saldo();


/* ── Reconstrucción y verificación ──
   `recalcular` demuestra el criterio de aceptación de reproducibilidad;
   `verificar` es la sonda que debe dar cero filas en producción, siempre. */

create or replace function app.recalcular_saldos()
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_filas bigint;
begin
  delete from saldos;

  insert into saldos (lote_id, ubicacion_id, sku, cantidad, actualizado_en)
  select m.lote_id, m.ubicacion_id, min(m.sku), sum(m.cantidad), now()
    from movimientos m
   group by m.lote_id, m.ubicacion_id
  having sum(m.cantidad) <> 0;

  get diagnostics v_filas = row_count;

  -- Las reservas activas se vuelven a aplicar sobre el saldo reconstruido.
  update saldos s
     set reservado = r.total
    from (select lote_id, ubicacion_id, sum(cantidad) as total
            from reservas where estado = 'ACTIVA'
           group by lote_id, ubicacion_id) r
   where s.lote_id = r.lote_id and s.ubicacion_id = r.ubicacion_id;

  return v_filas;
end;
$$;

create or replace function app.verificar_saldos()
returns table (
  lote_id      text,
  ubicacion_id text,
  segun_saldos numeric,
  segun_libro  numeric,
  diferencia   numeric
)
language sql
stable
as $$
  with libro as (
    select m.lote_id, m.ubicacion_id, sum(m.cantidad) as total
      from movimientos m
     group by m.lote_id, m.ubicacion_id
  )
  select coalesce(s.lote_id, l.lote_id),
         coalesce(s.ubicacion_id, l.ubicacion_id),
         coalesce(s.cantidad, 0),
         coalesce(l.total, 0),
         coalesce(s.cantidad, 0) - coalesce(l.total, 0)
    from saldos s
    full outer join libro l
      on l.lote_id = s.lote_id and l.ubicacion_id = s.ubicacion_id
   where coalesce(s.cantidad, 0) <> coalesce(l.total, 0);
$$;

comment on function app.verificar_saldos() is
  'Debe devolver cero filas. Cualquier fila es un descuadre entre la '
  'proyección y el libro, y se monitoriza a diario.';


/* ─────────────────────────── Reservas ───────────────────────────
   Confirmar un pedido compromete stock sin sacarlo del libro: la mercancía
   sigue en el almacén hasta que se sirve. Por eso la reserva toca
   `saldos.reservado` y no `saldos.cantidad`.
   ──────────────────────────────────────────────────────────────── */

create table reservas (
  reserva_id   uuid primary key default gen_random_uuid(),
  operacion_id uuid not null references operaciones (operacion_id),
  pedido_id    uuid,
  linea_id     uuid,
  sku          text not null references articulos (sku) on update cascade,
  lote_id      text not null references lotes (lote_id),
  ubicacion_id text not null references ubicaciones (ubicacion_id) on update cascade,
  cantidad     numeric(14,3) not null check (cantidad > 0),
  estado       estado_reserva not null default 'ACTIVA',
  creado_en    timestamptz not null default now(),
  cerrado_en   timestamptz,

  constraint reserva_cerrada_con_fecha
    check ((estado = 'ACTIVA' and cerrado_en is null)
        or (estado <> 'ACTIVA' and cerrado_en is not null))
);

create index reservas_activas on reservas (lote_id, ubicacion_id) where estado = 'ACTIVA';
create index reservas_por_pedido on reservas (pedido_id);


/* ─────────────────────────── Lote activo ───────────────────────────
   La decisión de diseño que evita entrada manual de datos: el lote que está
   a la venta en una ubicación no se declara en un formulario, se deduce del
   escaneo de reposición. Rellenar la vitrina YA es un traslado escaneado;
   ese mismo gesto deja aquí la huella que las ventas por webhook consultan.
   ──────────────────────────────────────────────────────────────── */

create table lote_activo (
  ubicacion_id text not null references ubicaciones (ubicacion_id) on update cascade,
  sku          text not null references articulos (sku) on update cascade,
  lote_id      text not null references lotes (lote_id),
  desde        timestamptz not null default now(),
  operacion_id uuid references operaciones (operacion_id),
  primary key (ubicacion_id, sku)
);

comment on table lote_activo is
  'Qué lote se está despachando de cada artículo en cada ubicación. Lo escribe '
  'automáticamente el traslado o la entrada; nadie lo teclea.';

-- ╔══ 20260920090300_04_pedidos.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  04 · PEDIDOS
--  La app NO emite documentos fiscales. Loyverse y WooCommerce ya son emisores
--  con Verifactu, y las facturas de ECI y hostelería las emite la gestoría.
--  Aquí solo se guarda la REFERENCIA al documento que emitió otro sistema,
--  para no duplicar registros ante la AEAT.
-- ═══════════════════════════════════════════════════════════════════════════

create table pedidos (
  pedido_id    uuid primary key default gen_random_uuid(),
  numero       text not null,
  operacion_id uuid references operaciones (operacion_id),
  cliente_id   uuid references clientes (cliente_id),
  canal        text not null,
  ubicacion_id text not null references ubicaciones (ubicacion_id) on update cascade,
  estado       estado_pedido not null default 'BORRADOR',

  fecha        date not null default current_date,

  -- Trazabilidad hacia el sistema que originó el pedido.
  origen       text not null default 'app'
                 check (origen in ('app','loyverse','woocommerce','eci','importacion','sistema')),
  origen_id    text,

  -- Referencia al documento fiscal ajeno. Nunca se genera aquí.
  documento_fiscal        text,
  documento_fiscal_sistema text
    check (documento_fiscal_sistema is null
           or documento_fiscal_sistema in ('loyverse','woocommerce','gestoria')),

  base       numeric(12,2) not null default 0,
  iva_pct    numeric(5,2)  not null default 21,
  iva        numeric(12,2) not null default 0,
  total      numeric(12,2) not null default 0,

  forma_pago text,
  notas      text,
  creado_por uuid references usuarios (usuario_id),
  creado_en  timestamptz not null default now(),

  constraint documento_fiscal_completo
    check ((documento_fiscal is null) = (documento_fiscal_sistema is null))
);

comment on column pedidos.documento_fiscal is
  'Número del ticket o factura tal y como lo emitió Loyverse, WooCommerce o '
  'la gestoría. Es una referencia, no un documento propio.';

create unique index pedidos_numero_unico on pedidos (numero);
create unique index pedidos_origen_unico
  on pedidos (origen, origen_id) where origen_id is not null;
create index pedidos_por_estado on pedidos (estado, fecha desc);
create index pedidos_por_cliente on pedidos (cliente_id, fecha desc);

create table pedido_lineas (
  linea_id    uuid primary key default gen_random_uuid(),
  pedido_id   uuid not null references pedidos (pedido_id) on delete cascade,
  sku         text not null references articulos (sku) on update cascade,
  cantidad    numeric(14,3) not null check (cantidad > 0),
  servidas    numeric(14,3) not null default 0 check (servidas >= 0),
  precio_unit numeric(12,4) not null default 0 check (precio_unit >= 0),
  dto_pct     numeric(5,2)  not null default 0 check (dto_pct between 0 and 100),
  importe     numeric(12,2) not null default 0,
  constraint no_servir_de_mas check (servidas <= cantidad)
);

create index lineas_por_pedido on pedido_lineas (pedido_id);

-- Ahora que existe `pedidos`, se cierra la referencia que dejó abierta la
-- migración del ledger.
alter table reservas
  add constraint reservas_pedido_fk
    foreign key (pedido_id) references pedidos (pedido_id) on delete cascade,
  add constraint reservas_linea_fk
    foreign key (linea_id) references pedido_lineas (linea_id) on delete cascade;

/* Vistas sin importes, para el rol OPERARIO.
   El operario no ve ningún importe: no es que estén ocultos en pantalla, es
   que su camino de lectura no los incluye. */

create view pedidos_operativo as
  select pedido_id, numero, cliente_id, canal, ubicacion_id, estado, fecha,
         origen, origen_id, forma_pago, notas, creado_por, creado_en
    from pedidos;

create view pedido_lineas_operativo as
  select linea_id, pedido_id, sku, cantidad, servidas
    from pedido_lineas;

-- ╔══ 20260920090400_05_ingesta.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  05 · INGESTA Y CONCILIACIÓN
--  Buzón de eventos externos con reintentos y cola de fallidos, y el registro
--  de todo lo que un humano tiene que mirar. El conector de Loyverse (fase 3)
--  se limitará a escribir aquí: el buzón ya existe desde el núcleo porque la
--  idempotencia no se puede añadir después.
-- ═══════════════════════════════════════════════════════════════════════════

create table eventos_entrada (
  evento_id    uuid primary key default gen_random_uuid(),
  canal        text not null check (canal in ('loyverse','woocommerce','eci','importacion','app')),
  tipo         text not null,
  origen_id    text not null,
  payload      jsonb not null,

  estado       estado_evento not null default 'PENDIENTE',
  intentos     integer not null default 0 check (intentos >= 0),
  ultimo_error text,
  proximo_intento_en timestamptz not null default now(),

  recibido_en  timestamptz not null default now(),
  procesado_en timestamptz,
  operacion_id uuid references operaciones (operacion_id),

  constraint procesado_con_fecha
    check ((estado = 'PROCESADO') = (procesado_en is not null))
);

comment on table eventos_entrada is
  'Primera parada de todo webhook. Se guarda el evento crudo ANTES de tocar '
  'el inventario: si el procesamiento falla, el hecho no se pierde y se puede '
  'reintentar sin volver a pedirle nada al sistema de origen.';

-- La defensa contra webhooks duplicados. Loyverse y WooCommerce reenvían.
create unique index eventos_sin_duplicados on eventos_entrada (canal, origen_id, tipo);

create index eventos_pendientes
  on eventos_entrada (proximo_intento_en)
  where estado in ('PENDIENTE', 'FALLIDO');

create index eventos_por_canal on eventos_entrada (canal, recibido_en desc);

-- Cola de fallidos: lo que ha agotado los reintentos y necesita a una persona.
create view eventos_muertos as
  select * from eventos_entrada
   where estado = 'FALLIDO' and intentos >= 8;

comment on view eventos_muertos is
  'Dead letter queue. Ocho intentos con espera exponencial (1 min → ~4 h) '
  'antes de rendirse y pedir ayuda.';

-- Espera exponencial con tope, para no machacar un sistema caído.
create or replace function app.espera_reintento(p_intentos integer)
returns interval
language sql
immutable
as $$
  select least(power(3, greatest(p_intentos, 0))::int, 14400) * interval '1 second';
$$;


/* ─────────────────────────── Incidencias ───────────────────────────
   La pantalla de conciliación se alimenta de aquí. Todo lo que el sistema no
   sabe resolver solo acaba en esta tabla en vez de fallar en silencio o, peor,
   de inventarse un dato.
   ──────────────────────────────────────────────────────────────── */

create table incidencias (
  incidencia_id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in (
    'SKU_DESCONOCIDO',      -- el canal vendió algo que no está mapeado
    'STOCK_INSUFICIENTE',   -- se vendió más de lo que decía haber
    'LOTE_SIN_RESOLVER',    -- no hay lote activo ni FIFO posible
    'EVENTO_FALLIDO',       -- agotó los reintentos
    'DESCUADRE_SALDO',      -- la proyección no cuadra con el libro
    'DEPOSITO_PENDIENTE'    -- informe de ECI sin cargar
  )),
  canal        text,
  referencia   text,
  detalle      jsonb not null default '{}'::jsonb,
  operacion_id uuid references operaciones (operacion_id),
  evento_id    uuid references eventos_entrada (evento_id),

  estado       estado_incidencia not null default 'ABIERTA',
  creado_en    timestamptz not null default now(),
  resuelto_en  timestamptz,
  resuelto_por uuid references usuarios (usuario_id),
  resolucion   text,

  constraint resuelta_con_fecha
    check ((estado = 'ABIERTA') = (resuelto_en is null))
);

create index incidencias_abiertas on incidencias (tipo, creado_en desc) where estado = 'ABIERTA';

create or replace function app.abrir_incidencia(
  p_tipo         text,
  p_canal        text default null,
  p_referencia   text default null,
  p_detalle      jsonb default '{}'::jsonb,
  p_operacion_id uuid default null,
  p_evento_id    uuid default null
) returns uuid
language sql
volatile
as $$
  insert into incidencias (tipo, canal, referencia, detalle, operacion_id, evento_id)
  values (p_tipo, p_canal, p_referencia, p_detalle, p_operacion_id, p_evento_id)
  returning incidencia_id;
$$;


/* ── Mapeo de códigos externos ↔ SKU interno ──
   Con 20-30 referencias se mantiene a mano, como acordamos. Lo que no se
   puede tolerar es que un código sin mapear pase desapercibido: por eso una
   venta de un código desconocido abre incidencia en lugar de descartarse. */

create table mapeo_articulos (
  canal       text not null check (canal in ('loyverse','woocommerce','eci')),
  codigo_externo text not null,
  sku         text not null references articulos (sku) on update cascade,
  descripcion_externa text,
  creado_en   timestamptz not null default now(),
  primary key (canal, codigo_externo)
);

create index mapeo_por_sku on mapeo_articulos (sku);

-- ╔══ 20260920090500_06_operaciones.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  06 · OPERACIONES DE DOMINIO
--
--  Estas funciones son la ÚNICA puerta de escritura al libro. Las políticas
--  RLS de la migración 07 niegan el INSERT directo sobre `movimientos` a todo
--  el mundo; solo estas funciones, que son SECURITY DEFINER, pueden anotar.
--
--  Consecuencia buscada: es imposible escribir en el inventario saltándose la
--  idempotencia, el control de rol o la proyección de saldos. No depende de
--  que nadie se acuerde de usar la capa correcta.
--
--  Todas reciben el operacion_id desde fuera (la PWA lo genera en el móvil,
--  antes de saber si hay cobertura) y todas son idempotentes.
-- ═══════════════════════════════════════════════════════════════════════════

create sequence if not exists pedidos_numero_seq;


/* ─────────────────────────── Apertura de operación ─────────────────────────── */

create or replace function app.abrir_operacion(
  p_operacion_id uuid,
  p_tipo         tipo_operacion,
  p_origen       text,
  p_origen_id    text,
  p_usuario_id   uuid,
  p_ocurrido_en  timestamptz,
  p_datos        jsonb,
  p_nota         text
) returns boolean
language plpgsql
as $$
begin
  insert into operaciones (operacion_id, tipo, origen, origen_id,
                           usuario_id, ocurrido_en, datos, nota)
  values (p_operacion_id, p_tipo, coalesce(p_origen, 'app'), p_origen_id,
          p_usuario_id, coalesce(p_ocurrido_en, now()),
          coalesce(p_datos, '{}'::jsonb), p_nota);
  return true;
exception
  -- Choca contra la clave primaria (reintento de la cola offline) o contra
  -- (origen, origen_id) (reenvío de webhook). Los dos casos son lo mismo:
  -- este hecho ya está contabilizado y no se vuelve a contabilizar.
  when unique_violation then
    return false;
end;
$$;

comment on function app.abrir_operacion is
  'Devuelve cierto solo la primera vez. Reprocesar el mismo hecho nunca '
  'duplica movimientos de stock.';


/* ─────────────────────────── Anotar en el libro ─────────────────────────── */

create or replace function app.anotar(
  p_operacion_id uuid,
  p_lote_id      text,
  p_ubicacion_id text,
  p_cantidad     numeric,
  p_ocurrido_en  timestamptz
) returns bigint
language plpgsql
as $$
declare
  v_sku        text;
  v_unidad     unidad_medida;
  v_id         bigint;
  v_restriccion text;
begin
  select l.sku, a.unidad into v_sku, v_unidad
    from lotes l join articulos a on a.sku = l.sku
   where l.lote_id = p_lote_id;

  if v_sku is null then
    raise exception 'El lote % no existe.', p_lote_id
      using errcode = 'foreign_key_violation';
  end if;

  -- Un paquete es indivisible: media bolsa no es una cantidad.
  if v_unidad = 'UD' and p_cantidad <> trunc(p_cantidad) then
    raise exception 'El artículo % se cuenta en unidades enteras (recibido %).',
      v_sku, p_cantidad using errcode = 'check_violation';
  end if;

  insert into movimientos (operacion_id, sku, lote_id, ubicacion_id, cantidad, ocurrido_en)
  values (p_operacion_id, v_sku, p_lote_id, p_ubicacion_id, p_cantidad, p_ocurrido_en)
  returning movimiento_id into v_id;

  return v_id;
exception
  when check_violation then
    -- El nombre de la restricción, no el texto del mensaje: el texto cambia
    -- con la versión de Postgres y con el idioma del servidor.
    get stacked diagnostics v_restriccion = constraint_name;

    if v_restriccion in ('saldo_nunca_negativo', 'reservado_coherente') then
      raise exception 'No hay stock suficiente del lote % en % (o está reservado).',
        p_lote_id, p_ubicacion_id
        using errcode = 'check_violation', hint = 'stock_insuficiente';
    end if;
    raise;
end;
$$;


/* ─────────────────────────── Identificadores de lote ─────────────────────────── */

create or replace function app.nuevo_lote_id(p_sku text, p_fecha date)
returns text
language plpgsql
as $$
declare
  v_cafe   text;
  v_clase  clase_articulo;
  v_gramos integer;
  v_base   text;
  v_n      integer;
begin
  select a.cafe_id, a.clase, f.gramos
    into v_cafe, v_clase, v_gramos
    from articulos a left join formatos f on f.formato_id = a.formato_id
   where a.sku = p_sku;

  if v_cafe is null then
    raise exception 'El artículo % no existe.', p_sku;
  end if;

  v_base := case v_clase when 'VERDE' then 'VRD' when 'GRANEL' then 'GRN' else 'CAF' end
            || '-' || v_cafe
            || coalesce('-' || v_gramos::text, '')
            || '-' || to_char(p_fecha, 'YYMMDD');

  select count(*) into v_n from lotes where lote_id like v_base || '-%';

  -- Segundo tueste del mismo café, formato y día → sufijo B.
  return v_base || '-' || case when v_n < 26 then chr(65 + v_n) else (v_n + 1)::text end;
end;
$$;


/* ─────────────────────────── Asignación de lote ───────────────────────────
   Cuando nadie escanea (una venta que llega por webhook) hay que decidir de
   qué lote sale la mercancía. La política es por ubicación:

     LOTE_ACTIVO → el lote que dejó el último escaneo de reposición. Si no
                   llega, el resto NO se reparte en silencio: sale como
                   `faltante` y acaba en la pantalla de conciliación.
                   Excepción: si esa ubicación aún no tiene lote activo para
                   ese artículo, se usa FIFO, para que la primera venta tras
                   el alta no se bloquee.
     FIFO        → el más antiguo con saldo. Es lo único posible en el depósito
                   de ECI, cuyas tiendas mezclan lotes y reportan agregado.

   El orden de FIFO es determinista (fecha, luego identificador) porque de él
   depende que reprocesar el histórico dé exactamente el mismo resultado.
   ──────────────────────────────────────────────────────────────── */

create or replace function app.asignar_lotes(
  p_ubicacion_id text,
  p_sku          text,
  p_cantidad     numeric
) returns jsonb
language plpgsql
stable
as $$
declare
  v_politica  politica_lote;
  v_activo    text;
  v_disp      numeric;
  v_resto     numeric := p_cantidad;
  v_toma      numeric;
  v_asignado  jsonb := '[]'::jsonb;
  v_usada     text;
  r           record;
begin
  select politica_lote into v_politica
    from ubicaciones where ubicacion_id = p_ubicacion_id and activo;

  if v_politica is null then
    raise exception 'La ubicación % no existe o está inactiva.', p_ubicacion_id;
  end if;

  v_usada := v_politica::text;

  if v_politica = 'LOTE_ACTIVO' then
    select la.lote_id, coalesce(s.disponible, 0)
      into v_activo, v_disp
      from lote_activo la
      left join saldos s
        on s.lote_id = la.lote_id and s.ubicacion_id = la.ubicacion_id
     where la.ubicacion_id = p_ubicacion_id and la.sku = p_sku;

    if v_activo is not null then
      v_toma := least(greatest(v_disp, 0), v_resto);
      if v_toma > 0 then
        v_asignado := v_asignado ||
          jsonb_build_array(jsonb_build_object('lote_id', v_activo, 'cantidad', v_toma));
        v_resto := v_resto - v_toma;
      end if;
      return jsonb_build_object('asignado', v_asignado,
                                'faltante', v_resto,
                                'politica', v_usada);
    end if;

    -- Sin lote activo declarado todavía: no bloqueamos la venta.
    v_usada := 'FIFO_SIN_LOTE_ACTIVO';
  end if;

  for r in
    select s.lote_id, s.disponible
      from saldos s
      join lotes l on l.lote_id = s.lote_id
     where s.ubicacion_id = p_ubicacion_id
       and s.sku = p_sku
       and s.disponible > 0
     order by coalesce(l.fecha_tostado, l.fecha_recepcion, l.creado_en::date),
              l.lote_id
  loop
    exit when v_resto <= 0;
    v_toma := least(r.disponible, v_resto);
    v_asignado := v_asignado ||
      jsonb_build_array(jsonb_build_object('lote_id', r.lote_id, 'cantidad', v_toma));
    v_resto := v_resto - v_toma;
  end loop;

  return jsonb_build_object('asignado', v_asignado,
                            'faltante', v_resto,
                            'politica', v_usada);
end;
$$;


/* ─────────────────────────── Recepción de café verde ─────────────────────────── */

create or replace function registrar_recepcion_verde(
  p_operacion_id   uuid,
  p_sku            text,
  p_cantidad_kg    numeric,
  p_ubicacion_id   text,
  p_proveedor      text default null,
  p_fecha_recepcion date default null,
  p_precio_kg      numeric default null,
  p_usuario_id     uuid default null,
  p_ocurrido_en    timestamptz default now(),
  p_lote_id        text default null,
  p_nota           text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_lote  text;
  v_fecha date := coalesce(p_fecha_recepcion, (p_ocurrido_en at time zone 'Europe/Madrid')::date);
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para dar de alta café verde.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_cantidad_kg <= 0 then
    raise exception 'Los kilos recibidos tienen que ser positivos.';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'RECEPCION_VERDE', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('sku', p_sku,
                                                'cantidad_kg', p_cantidad_kg,
                                                'ubicacion_id', p_ubicacion_id,
                                                'proveedor', p_proveedor,
                                                'fecha_recepcion', v_fecha,
                                                'precio_kg', p_precio_kg), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  v_lote := coalesce(p_lote_id, app.nuevo_lote_id(p_sku, v_fecha));

  insert into lotes (lote_id, sku, proveedor, fecha_recepcion, precio_kg, notas, creado_por)
  values (v_lote, p_sku, p_proveedor, v_fecha, p_precio_kg, p_nota, p_usuario_id);

  perform app.anotar(p_operacion_id, v_lote, p_ubicacion_id, p_cantidad_kg, p_ocurrido_en);

  update operaciones set datos = datos || jsonb_build_object('lote_id', v_lote)
   where operacion_id = p_operacion_id;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'lote_id', v_lote,
                            'kg', p_cantidad_kg);
end;
$$;


/* ─────────────────────────── Tueste ───────────────────────────
   Una transformación, no dos apuntes sueltos: consume kilos de uno o varios
   sacos de verde y produce paquetes, todo bajo la misma operación y dentro
   de la misma transacción. La merma sale de la diferencia de pesos reales,
   no de un porcentaje configurado, y queda registrada en la operación.

   Admite varios sacos de origen porque la mezcla de la casa son dos.
   ──────────────────────────────────────────────────────────────── */

create or replace function registrar_tueste(
  p_operacion_id uuid,
  p_consumos     jsonb,   -- [{"lote_id":"VRD-…","cantidad": 25.0}]
  p_producciones jsonb,   -- [{"sku":"ETH-250-GR","cantidad": 78, "lote_id": null}]
  p_ubicacion_id text,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_nota         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fecha     date := (p_ocurrido_en at time zone 'Europe/Madrid')::date;
  v_kg_entra  numeric := 0;
  v_kg_sale   numeric := 0;
  v_dias      integer;
  v_lote      text;
  v_gramos    integer;
  v_lotes_out jsonb := '[]'::jsonb;
  c           record;
  p           record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para registrar un tueste.'
      using errcode = 'insufficient_privilege';
  end if;
  if jsonb_array_length(coalesce(p_consumos, '[]'::jsonb)) = 0 then
    raise exception 'Un tueste tiene que consumir café verde.';
  end if;
  if jsonb_array_length(coalesce(p_producciones, '[]'::jsonb)) = 0 then
    raise exception 'Un tueste tiene que producir algo.';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'TUESTE', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('consumos', p_consumos,
                                                'producciones', p_producciones,
                                                'ubicacion_id', p_ubicacion_id), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  -- Sale el verde.
  for c in select * from jsonb_to_recordset(p_consumos) as x(lote_id text, cantidad numeric)
  loop
    if c.cantidad <= 0 then
      raise exception 'Los kilos consumidos del lote % tienen que ser positivos.', c.lote_id;
    end if;
    perform app.anotar(p_operacion_id, c.lote_id, p_ubicacion_id, -c.cantidad, p_ocurrido_en);
    v_kg_entra := v_kg_entra + c.cantidad;
  end loop;

  v_dias := app.parametro_int('dias_consumo_preferente', 365);

  -- Entra el tostado.
  for p in select * from jsonb_to_recordset(p_producciones)
                     as x(sku text, cantidad numeric, lote_id text)
  loop
    if p.cantidad <= 0 then
      raise exception 'Las unidades producidas de % tienen que ser positivas.', p.sku;
    end if;

    select f.gramos into v_gramos
      from articulos a join formatos f on f.formato_id = a.formato_id
     where a.sku = p.sku;

    if v_gramos is null then
      raise exception 'El artículo % no es un paquete con formato.', p.sku;
    end if;

    v_lote := coalesce(p.lote_id, app.nuevo_lote_id(p.sku, v_fecha));

    insert into lotes (lote_id, sku, fecha_tostado, fecha_consumo_preferente,
                       notas, creado_por)
    values (v_lote, p.sku, v_fecha, v_fecha + v_dias, p_nota, p_usuario_id);

    perform app.anotar(p_operacion_id, v_lote, p_ubicacion_id, p.cantidad, p_ocurrido_en);

    -- Ascendencia: de qué sacos salió este lote, repartida a prorrata.
    insert into lote_composicion (lote_hijo_id, lote_padre_id, cantidad)
    select v_lote, c2.lote_id, round(c2.cantidad * (p.cantidad * v_gramos / 1000.0)
           / nullif(v_kg_entra, 0), 3)
      from jsonb_to_recordset(p_consumos) as c2(lote_id text, cantidad numeric)
    on conflict do nothing;

    v_kg_sale := v_kg_sale + (p.cantidad * v_gramos / 1000.0);
    v_lotes_out := v_lotes_out ||
      jsonb_build_array(jsonb_build_object('lote_id', v_lote, 'sku', p.sku,
                                           'cantidad', p.cantidad));
  end loop;

  update operaciones
     set datos = datos || jsonb_build_object(
           'producciones', v_lotes_out,
           'kg_verde', v_kg_entra,
           'kg_tostado', round(v_kg_sale, 3),
           'merma_pct', round((v_kg_entra - v_kg_sale) / nullif(v_kg_entra, 0) * 100, 2),
           'lotes', v_lotes_out)
   where operacion_id = p_operacion_id;

  return jsonb_build_object(
    'idempotente', false,
    'operacion_id', p_operacion_id,
    'lotes', v_lotes_out,
    'kg_verde', v_kg_entra,
    'kg_tostado', round(v_kg_sale, 3),
    'merma_pct', round((v_kg_entra - v_kg_sale) / nullif(v_kg_entra, 0) * 100, 2));
end;
$$;


/* ─────────────────────────── Traslado ───────────────────────────
   Servir a El Corte Inglés es esto y no una venta: la mercancía cambia de
   sitio, sigue siendo nuestra y el stock total no baja. Además, el traslado
   deja marcado el lote activo en el destino, que es lo que convierte el
   escaneo de reposición en la declaración que luego usan los webhooks.
   ──────────────────────────────────────────────────────────────── */

create or replace function registrar_traslado(
  p_operacion_id uuid,
  p_lote_id      text,
  p_origen_ubicacion  text,
  p_destino_ubicacion text,
  p_cantidad     numeric,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_nota         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sku text;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para mover mercancía.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_origen_ubicacion = p_destino_ubicacion then
    raise exception 'El origen y el destino del traslado son el mismo sitio.';
  end if;
  if p_cantidad <= 0 then
    raise exception 'La cantidad trasladada tiene que ser positiva.';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'TRASLADO', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('lote_id', p_lote_id,
                                                'de', p_origen_ubicacion,
                                                'a', p_destino_ubicacion,
                                                'cantidad', p_cantidad), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  select sku into v_sku from lotes where lote_id = p_lote_id;

  perform app.anotar(p_operacion_id, p_lote_id, p_origen_ubicacion,  -p_cantidad, p_ocurrido_en);
  perform app.anotar(p_operacion_id, p_lote_id, p_destino_ubicacion,  p_cantidad, p_ocurrido_en);

  -- El gesto físico de reponer ES la declaración del lote activo.
  insert into lote_activo (ubicacion_id, sku, lote_id, desde, operacion_id)
  values (p_destino_ubicacion, v_sku, p_lote_id, p_ocurrido_en, p_operacion_id)
  on conflict (ubicacion_id, sku) do update
    set lote_id = excluded.lote_id,
        desde = excluded.desde,
        operacion_id = excluded.operacion_id;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'sku', v_sku,
                            'lote_activo_en_destino', p_lote_id);
end;
$$;


/* ─────────────────────────── Venta ─────────────────────────── */

create or replace function registrar_venta(
  p_operacion_id uuid,
  p_ubicacion_id text,
  p_lineas       jsonb,   -- [{"sku":…, "cantidad":…, "lote_id":opcional, "precio_unit":…}]
  p_canal        text default 'Mostrador',
  p_cliente_id   uuid default null,
  p_origen       text default 'app',
  p_origen_id    text default null,
  p_documento_fiscal text default null,
  p_documento_fiscal_sistema text default null,
  p_forma_pago   text default null,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_evento_id    uuid default null,
  p_nota         text default null,
  p_permitir_faltante boolean default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido    uuid;
  v_numero    text;
  v_permite   boolean;
  v_asig      jsonb;
  v_linea     uuid;
  v_precio    numeric;
  v_importe   numeric;
  v_base      numeric := 0;
  v_servidas  numeric;
  v_faltante  numeric;
  v_incid     jsonb := '[]'::jsonb;
  v_iva_pct   numeric := 21;
  v_permitir  boolean;
  l           record;
  a           record;
begin
  -- Una venta que llega de Loyverse o de WooCommerce YA ha ocurrido en el
  -- mundo real: negarse a registrarla no devuelve el café al estante, solo
  -- pierde el dato. Se anota lo que había y la diferencia va a conciliación.
  --
  -- Una venta que se está tecleando en el mostrador todavía no ha ocurrido:
  -- ahí lo correcto es fallar y que el empleado lo sepa antes de cobrar.
  v_permitir := coalesce(p_permitir_faltante, coalesce(p_origen, 'app') <> 'app');
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para registrar una venta.'
      using errcode = 'insufficient_privilege';
  end if;

  select permite_venta into v_permite
    from ubicaciones where ubicacion_id = p_ubicacion_id and activo;
  if v_permite is null then
    raise exception 'La ubicación % no existe o está inactiva.', p_ubicacion_id;
  end if;
  if not v_permite then
    raise exception 'Desde % no se vende: la salida de ahí es un traslado.', p_ubicacion_id;
  end if;

  if not app.abrir_operacion(p_operacion_id, 'VENTA', p_origen, p_origen_id,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('lineas', p_lineas,
                                                'canal', p_canal,
                                                'ubicacion_id', p_ubicacion_id,
                                                'cliente_id', p_cliente_id,
                                                'forma_pago', p_forma_pago,
                                                'documento_fiscal', p_documento_fiscal,
                                                'documento_fiscal_sistema',
                                                  p_documento_fiscal_sistema), p_nota) then
    return jsonb_build_object(
      'idempotente', true,
      'operacion_id', p_operacion_id,
      'pedido_id', (select pedido_id from pedidos
                     where operacion_id = p_operacion_id
                        or (origen = p_origen and origen_id = p_origen_id
                            and p_origen_id is not null)
                     limit 1));
  end if;

  v_numero := 'PED-' || to_char(p_ocurrido_en, 'YYYY') || '-' ||
              lpad(nextval('pedidos_numero_seq')::text, 5, '0');

  insert into pedidos (pedido_id, numero, operacion_id, cliente_id, canal, ubicacion_id,
                       estado, fecha, origen, origen_id,
                       documento_fiscal, documento_fiscal_sistema,
                       iva_pct, forma_pago, notas, creado_por)
  values (gen_random_uuid(), v_numero, p_operacion_id, p_cliente_id, p_canal, p_ubicacion_id,
          'ENTREGADO', (p_ocurrido_en at time zone 'Europe/Madrid')::date,
          p_origen, p_origen_id, p_documento_fiscal, p_documento_fiscal_sistema,
          v_iva_pct, p_forma_pago, p_nota, p_usuario_id)
  returning pedido_id into v_pedido;

  for l in select * from jsonb_to_recordset(p_lineas)
                    as x(sku text, cantidad numeric, lote_id text,
                         precio_unit numeric, dto_pct numeric)
  loop
    if l.cantidad <= 0 then
      raise exception 'La cantidad vendida de % tiene que ser positiva.', l.sku;
    end if;

    -- El precio lo pone el canal, que es quien ha cobrado. Si no viene
    -- (venta de mostrador desde el escáner), se toma el de tarifa.
    v_precio := coalesce(l.precio_unit,
                         (select precio_venta from precios where sku = l.sku), 0);
    v_importe := round(v_precio * l.cantidad * (1 - coalesce(l.dto_pct, 0) / 100), 2);
    v_base := v_base + v_importe;

    insert into pedido_lineas (pedido_id, sku, cantidad, precio_unit, dto_pct, importe)
    values (v_pedido, l.sku, l.cantidad, v_precio, coalesce(l.dto_pct, 0), v_importe)
    returning linea_id into v_linea;

    if l.lote_id is not null then
      -- El operario ha escaneado la bolsa: no hay nada que deducir.
      perform app.anotar(p_operacion_id, l.lote_id, p_ubicacion_id, -l.cantidad, p_ocurrido_en);
      v_servidas := l.cantidad;
      v_faltante := 0;
    else
      v_asig := app.asignar_lotes(p_ubicacion_id, l.sku, l.cantidad);
      v_faltante := (v_asig ->> 'faltante')::numeric;
      v_servidas := l.cantidad - v_faltante;

      for a in select * from jsonb_to_recordset(v_asig -> 'asignado')
                         as y(lote_id text, cantidad numeric)
      loop
        perform app.anotar(p_operacion_id, a.lote_id, p_ubicacion_id, -a.cantidad, p_ocurrido_en);
      end loop;

      if v_faltante > 0 and not v_permitir then
        raise exception 'No hay stock suficiente de % en %: faltan % de %.',
          l.sku, p_ubicacion_id, v_faltante, l.cantidad
          using errcode = 'check_violation', hint = 'stock_insuficiente';
      end if;

      if v_faltante > 0 then
        -- No se inventa stock ni se descarta la venta: queda anotado lo que
        -- sí había y la diferencia va a la pantalla de conciliación, con el
        -- canal y el evento que la originaron.
        v_incid := v_incid || jsonb_build_array(app.abrir_incidencia(
          case when (v_asig ->> 'politica') = 'LOTE_ACTIVO'
               then 'LOTE_SIN_RESOLVER' else 'STOCK_INSUFICIENTE' end,
          p_origen, coalesce(p_origen_id, v_numero),
          jsonb_build_object('sku', l.sku, 'ubicacion', p_ubicacion_id,
                             'pedida', l.cantidad, 'servida', v_servidas,
                             'faltante', v_faltante, 'politica', v_asig ->> 'politica'),
          p_operacion_id, p_evento_id));
      end if;
    end if;

    update pedido_lineas set servidas = v_servidas where linea_id = v_linea;
  end loop;

  update pedidos
     set base  = round(v_base / (1 + v_iva_pct / 100), 2),
         iva   = round(v_base - v_base / (1 + v_iva_pct / 100), 2),
         total = round(v_base, 2),
         estado = (case when jsonb_array_length(v_incid) > 0
                        then 'SERVIDO' else 'ENTREGADO' end)::estado_pedido
   where pedido_id = v_pedido;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'pedido_id', v_pedido,
                            'numero', v_numero,
                            'total', round(v_base, 2),
                            'incidencias', v_incid);
end;
$$;

/* ─────────────────────────── Movimiento suelto ───────────────────────────
   Entradas, salidas y mermas sin origen comercial: muestras, autoconsumo,
   roturas, devoluciones. Sigue siendo una operación idempotente.
   ──────────────────────────────────────────────────────────────── */

create or replace function registrar_movimiento(
  p_operacion_id uuid,
  p_tipo         tipo_operacion,
  p_lote_id      text,
  p_ubicacion_id text,
  p_cantidad     numeric,      -- siempre positiva; el signo lo pone el tipo
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_nota         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_signo int;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para mover stock.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_tipo not in ('ENTRADA', 'SALIDA', 'MERMA', 'DEVOLUCION') then
    raise exception 'registrar_movimiento no admite el tipo %. Usa la función específica.', p_tipo;
  end if;
  if p_cantidad <= 0 then
    raise exception 'La cantidad tiene que ser positiva: el signo lo decide el tipo de operación.';
  end if;

  v_signo := case when p_tipo in ('SALIDA', 'MERMA') then -1 else 1 end;

  if not app.abrir_operacion(p_operacion_id, p_tipo, 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('lote_id', p_lote_id,
                                                'ubicacion', p_ubicacion_id,
                                                'cantidad', p_cantidad), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  perform app.anotar(p_operacion_id, p_lote_id, p_ubicacion_id,
                     v_signo * p_cantidad, p_ocurrido_en);

  -- Una entrada también repone: deja el lote activo puesto en esa ubicación.
  if v_signo > 0 then
    insert into lote_activo (ubicacion_id, sku, lote_id, desde, operacion_id)
    select p_ubicacion_id, sku, p_lote_id, p_ocurrido_en, p_operacion_id
      from lotes where lote_id = p_lote_id
    on conflict (ubicacion_id, sku) do update
      set lote_id = excluded.lote_id, desde = excluded.desde,
          operacion_id = excluded.operacion_id;
  end if;

  return jsonb_build_object('idempotente', false, 'operacion_id', p_operacion_id);
end;
$$;


/* ─────────────────────────── Recuento físico ───────────────────────────
   Un inventario no sobrescribe el stock: genera los ajustes que explican la
   diferencia. El descuadre queda en el libro, con su fecha y su responsable,
   en vez de desaparecer.
   ──────────────────────────────────────────────────────────────── */

create or replace function registrar_ajuste_inventario(
  p_operacion_id uuid,
  p_ubicacion_id text,
  p_recuento     jsonb,   -- [{"lote_id":"CAF-…","contado": 37}]
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_nota         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_teorico numeric;
  v_dif     numeric;
  v_ajustes jsonb := '[]'::jsonb;
  r         record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para hacer un recuento.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'AJUSTE', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('ubicacion', p_ubicacion_id,
                                                'recuento', p_recuento), p_nota) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for r in select * from jsonb_to_recordset(p_recuento) as x(lote_id text, contado numeric)
  loop
    select coalesce(cantidad, 0) into v_teorico
      from saldos where lote_id = r.lote_id and ubicacion_id = p_ubicacion_id;

    v_dif := r.contado - coalesce(v_teorico, 0);
    continue when v_dif = 0;

    perform app.anotar(p_operacion_id, r.lote_id, p_ubicacion_id, v_dif, p_ocurrido_en);

    v_ajustes := v_ajustes || jsonb_build_array(jsonb_build_object(
      'lote_id', r.lote_id, 'teorico', coalesce(v_teorico, 0),
      'contado', r.contado, 'diferencia', v_dif));
  end loop;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'ajustes', v_ajustes);
end;
$$;


/* ─────────────────────────── Reservas ───────────────────────────
   Confirmar un pedido compromete el stock; servirlo lo descuenta. Entre esos
   dos momentos la mercancía sigue en el libro, pero deja de estar disponible
   para otro canal. Es lo que evita vender dos veces el mismo paquete desde
   la web y desde el mercado.
   ──────────────────────────────────────────────────────────────── */

create or replace function reservar_pedido(
  p_operacion_id uuid,
  p_pedido_id    uuid,
  p_ubicacion_id text,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_asig    jsonb;
  v_reservas jsonb := '[]'::jsonb;
  v_falta   numeric;
  v_incid   jsonb := '[]'::jsonb;
  l         record;
  a         record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para reservar stock.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'RESERVA', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id), null) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for l in select linea_id, sku, cantidad - servidas as pendiente
             from pedido_lineas where pedido_id = p_pedido_id and cantidad > servidas
  loop
    v_asig := app.asignar_lotes(p_ubicacion_id, l.sku, l.pendiente);
    v_falta := (v_asig ->> 'faltante')::numeric;

    for a in select * from jsonb_to_recordset(v_asig -> 'asignado')
                       as y(lote_id text, cantidad numeric)
    loop
      insert into reservas (operacion_id, pedido_id, linea_id, sku,
                            lote_id, ubicacion_id, cantidad)
      values (p_operacion_id, p_pedido_id, l.linea_id, l.sku,
              a.lote_id, p_ubicacion_id, a.cantidad);

      -- Reservar no saca nada del libro: marca la parte comprometida.
      update saldos set reservado = reservado + a.cantidad, actualizado_en = now()
       where lote_id = a.lote_id and ubicacion_id = p_ubicacion_id;

      v_reservas := v_reservas || jsonb_build_array(
        jsonb_build_object('lote_id', a.lote_id, 'cantidad', a.cantidad));
    end loop;

    if v_falta > 0 then
      v_incid := v_incid || jsonb_build_array(app.abrir_incidencia(
        'STOCK_INSUFICIENTE', 'app', p_pedido_id::text,
        jsonb_build_object('sku', l.sku, 'faltante', v_falta),
        p_operacion_id, null));
    end if;
  end loop;

  update pedidos set estado = 'CONFIRMADO'
   where pedido_id = p_pedido_id and estado = 'BORRADOR';

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'reservas', v_reservas,
                            'incidencias', v_incid);
end;
$$;

create or replace function servir_reservas_pedido(
  p_operacion_id uuid,
  p_pedido_id    uuid,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total numeric := 0;
  r       record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para servir un pedido.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'VENTA', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id,
                                                'desde', 'reservas'), null) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for r in select * from reservas
            where pedido_id = p_pedido_id and estado = 'ACTIVA'
            order by reserva_id
  loop
    -- Primero se suelta la reserva y después se anota la salida. En el otro
    -- orden, la restricción reservado <= cantidad rechazaría el movimiento.
    update saldos set reservado = reservado - r.cantidad, actualizado_en = now()
     where lote_id = r.lote_id and ubicacion_id = r.ubicacion_id;

    perform app.anotar(p_operacion_id, r.lote_id, r.ubicacion_id, -r.cantidad, p_ocurrido_en);

    update reservas set estado = 'SERVIDA', cerrado_en = now()
     where reserva_id = r.reserva_id;

    update pedido_lineas set servidas = servidas + r.cantidad
     where linea_id = r.linea_id;

    v_total := v_total + r.cantidad;
  end loop;

  update pedidos set estado = 'SERVIDO' where pedido_id = p_pedido_id;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'unidades', v_total);
end;
$$;

create or replace function liberar_reservas_pedido(
  p_operacion_id uuid,
  p_pedido_id    uuid,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n int := 0;
  r   record;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para liberar reservas.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'LIBERACION', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id), null) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for r in select * from reservas where pedido_id = p_pedido_id and estado = 'ACTIVA'
  loop
    update saldos set reservado = reservado - r.cantidad, actualizado_en = now()
     where lote_id = r.lote_id and ubicacion_id = r.ubicacion_id;
    update reservas set estado = 'LIBERADA', cerrado_en = now()
     where reserva_id = r.reserva_id;
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id, 'liberadas', v_n);
end;
$$;

-- ╔══ 20260920090600_07_rls.sql ══╗

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

-- ╔══ 20260920090700_08_semilla.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  08 · SEMILLA
--  Lo mínimo imprescindible para que la app arranque: las ubicaciones reales
--  del negocio y un administrador. Es idempotente: se puede volver a aplicar.
-- ═══════════════════════════════════════════════════════════════════════════

insert into ubicaciones (ubicacion_id, nombre, tipo, politica_lote, permite_venta, notas) values
  ('ALMACEN',  'Almacén y obrador', 'PROPIA',   'FIFO',        false,
   'Origen de todo. No se vende desde aquí: la salida hacia otro sitio es un traslado.'),
  ('TIENDA',   'Tienda física',     'PROPIA',   'LOTE_ACTIVO', true,
   'Ventas de Loyverse. El lote activo lo deja el escaneo de reposición.'),
  ('FURGONETA','Furgoneta de mercados', 'PROPIA','LOTE_ACTIVO', true,
   'Se carga antes de cada feria y se descarga al volver.'),
  ('ONLINE',   'Stock reservado a la web', 'PROPIA', 'LOTE_ACTIVO', true,
   'Lo que WooCommerce puede vender. Separarlo evita vender por web lo que va en la furgoneta.'),
  ('DEPOSITO_ECI', 'Depósito El Corte Inglés', 'DEPOSITO', 'FIFO', true,
   'Mercancía nuestra en sus tiendas. Servir aquí es un traslado, no una venta. '
   'Durante la prueba se lleva a mano: el informe de ventas se carga manualmente. '
   'FIFO por fuerza: sus tiendas mezclan lotes y reportan ventas agregadas.')
on conflict (ubicacion_id) do nothing;

-- Administrador inicial. El PIN 1234 hay que cambiarlo antes de usar la app
-- de verdad; la pantalla de ajustes avisa mientras siga puesto.
insert into usuarios (nombre, pin_hash, rol)
select 'Administrador', app.hash_pin('1234'), 'ADMIN'
 where not exists (select 1 from usuarios);

-- ╔══ 20260920090800_09_reproduccion.sql ══╗

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
--  `registrar_devolucion`, `registrar_pedido_canal` y `servir_linea_escaneada`
--  se definen más adelante (migraciones 14, 15 y 21). PL/pgSQL resuelve las llamadas al ejecutar, no al
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
        if v_datos ->> 'desde' in ('reservas', 'escaner') then
          v_pedido := (pedido_de_canal(v_datos ->> 'pedido_origen',
                                       v_datos ->> 'pedido_origen_id') ->> 'pedido_id')::uuid;
          if v_pedido is null then
            v_omitidas := v_omitidas + 1;
            continue;
          end if;

          if v_datos ->> 'desde' = 'escaner' then
            -- Preparación con escáner: se sirvió un lote concreto, no las
            -- reservas. Reproducirlo como si fueran reservas cambiaría de qué
            -- lote salió la mercancía.
            perform servir_linea_escaneada(
              v_id, v_pedido, v_datos ->> 'lote_id',
              (v_datos ->> 'cantidad')::numeric, v_usuario, v_cuando);
          else
            perform servir_reservas_pedido(
              v_id, v_pedido, v_usuario, v_cuando,
              coalesce(o ->> 'origen', 'app'), o ->> 'origen_id');
          end if;
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

-- ╔══ 20260920090900_10_vistas.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  10 · VISTAS DE CONSULTA
--  Todo se deriva del libro. Ninguna de estas vistas guarda nada.
-- ═══════════════════════════════════════════════════════════════════════════

/* Stock consolidado por artículo y ubicación. */
create view v_stock as
  select s.sku,
         a.cafe_id,
         c.nombre       as cafe,
         f.nombre       as formato,
         a.unidad,
         s.ubicacion_id,
         u.nombre       as ubicacion,
         u.tipo         as tipo_ubicacion,
         sum(s.cantidad)   as cantidad,
         sum(s.reservado)  as reservado,
         sum(s.disponible) as disponible,
         count(*)          as lotes
    from saldos s
    join articulos a  on a.sku = s.sku
    join cafes c      on c.cafe_id = a.cafe_id
    left join formatos f on f.formato_id = a.formato_id
    join ubicaciones u on u.ubicacion_id = s.ubicacion_id
   group by s.sku, a.cafe_id, c.nombre, f.nombre, a.unidad,
            s.ubicacion_id, u.nombre, u.tipo;

/* Frescura: cuántos días lleva cada lote desde el tueste. Los umbrales salen
   de parámetros, no del código, para poder ajustarlos al perfil de la casa. */
create view v_frescura as
  select s.lote_id, s.sku, s.ubicacion_id, s.cantidad,
         l.fecha_tostado,
         l.fecha_consumo_preferente,
         (current_date - l.fecha_tostado) as dias_desde_tueste,
         case
           when l.fecha_tostado is null then 'SIN_FECHA'
           when current_date - l.fecha_tostado >= app.parametro_int('dias_frescura_critico', 90)
             then 'CRITICO'
           when current_date - l.fecha_tostado >= app.parametro_int('dias_frescura_aviso', 45)
             then 'AVISO'
           else 'FRESCO'
         end as frescura
    from saldos s
    join lotes l on l.lote_id = s.lote_id
   where s.cantidad > 0 and l.fecha_tostado is not null;

/* ── Depósito ──
   El criterio de aceptación del régimen de depósito, expresado como consulta:
   lo que queda tiene que ser lo servido, menos lo reportado como vendido,
   menos lo devuelto. Las tres cifras salen del mismo libro, así que no pueden
   discrepar del saldo: si lo hicieran, el descuadre sería visible aquí.

   Vale para cualquier ubicación de tipo DEPOSITO. Durante la prueba con El
   Corte Inglés los tres apuntes se cargan a mano; el día que haya integración
   los escribirá el conector y esta vista no cambia. */
create view v_deposito as
  with apuntes as (
    select m.ubicacion_id,
           m.sku,
           m.lote_id,
           sum(m.cantidad) filter (where o.tipo = 'TRASLADO'   and m.cantidad > 0) as servido,
           sum(m.cantidad) filter (where o.tipo = 'TRASLADO'   and m.cantidad < 0) as devuelto,
           sum(m.cantidad) filter (where o.tipo = 'VENTA')                          as vendido,
           sum(m.cantidad) filter (where o.tipo not in ('TRASLADO','VENTA'))        as otros,
           min(m.ocurrido_en) filter (where o.tipo = 'TRASLADO' and m.cantidad > 0) as primera_entrega
      from movimientos m
      join operaciones o  on o.operacion_id = m.operacion_id
      join ubicaciones ub on ub.ubicacion_id = m.ubicacion_id
     where ub.tipo = 'DEPOSITO'
     group by m.ubicacion_id, m.sku, m.lote_id
  )
  select ap.ubicacion_id,
         ap.sku,
         ap.lote_id,
         coalesce(ap.servido, 0)        as servido,
         -coalesce(ap.vendido, 0)       as vendido,
         -coalesce(ap.devuelto, 0)      as devuelto,
         coalesce(ap.otros, 0)          as otros_ajustes,
         coalesce(s.cantidad, 0)        as saldo,
         -- Debe ser siempre cero. Si no lo es, hay un descuadre que mirar.
         coalesce(s.cantidad, 0)
           - (coalesce(ap.servido, 0) + coalesce(ap.vendido, 0)
              + coalesce(ap.devuelto, 0) + coalesce(ap.otros, 0)) as descuadre,
         ap.primera_entrega,
         (current_date - ap.primera_entrega::date) as dias_en_deposito,
         (current_date - ap.primera_entrega::date)
           >= app.parametro_int('dias_antiguedad_deposito', 90) as envejecido
    from apuntes ap
    left join saldos s
      on s.lote_id = ap.lote_id and s.ubicacion_id = ap.ubicacion_id;

comment on view v_deposito is
  'Servido − vendido − devuelto = saldo, para cada lote en depósito. '
  'La columna `descuadre` tiene que ser cero siempre. Incluye la antigüedad '
  'para saber qué lleva demasiado tiempo fuera.';

/* Trazabilidad: de un lote de venta hacia atrás, hasta los sacos de origen. */
create view v_trazabilidad as
  with recursive arbol as (
    select l.lote_id as lote, l.lote_id as ancestro, 0 as nivel, l.sku, l.fecha_tostado
      from lotes l
    union all
    select a.lote, lc.lote_padre_id, a.nivel + 1, a.sku, a.fecha_tostado
      from arbol a
      join lote_composicion lc on lc.lote_hijo_id = a.ancestro
  )
  select ar.lote,
         ar.nivel,
         ar.ancestro           as lote_origen,
         lo.sku                as sku_origen,
         lo.proveedor,
         lo.fecha_recepcion
    from arbol ar
    join lotes lo on lo.lote_id = ar.ancestro
   where ar.nivel > 0;

grant select on v_stock, v_frescura, v_deposito, v_trazabilidad to authenticated;

-- ╔══ 20260920091000_11_acceso.sql ══╗

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
set search_path = public, extensions, pg_temp
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

-- ╔══ 20260920091100_12_vistas_app.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  12 · VISTAS PARA LA APP
--  Lo que la PWA necesita llevarse al móvil para poder trabajar sin cobertura.
-- ═══════════════════════════════════════════════════════════════════════════

/* Ficha completa de un lote: es lo que se resuelve al escanear un QR.
   Se cachea entera en el móvil, así que un escaneo sin red sigue diciendo
   qué café es, cuándo se tostó y cuántos días lleva. */
create view v_lote_detalle as
  select l.lote_id,
         l.sku,
         a.clase,
         a.unidad,
         a.ean13,
         a.cafe_id,
         c.nombre            as cafe,
         c.origen,
         c.perfil_tueste,
         f.formato_id,
         f.nombre            as formato,
         f.gramos,
         f.molienda,
         l.fecha_tostado,
         l.fecha_consumo_preferente,
         l.fecha_recepcion,
         l.proveedor,
         case when l.fecha_tostado is null then null
              else current_date - l.fecha_tostado end as dias_desde_tueste,
         case
           when l.fecha_tostado is null then 'SIN_FECHA'
           when current_date - l.fecha_tostado >= app.parametro_int('dias_frescura_critico', 90)
             then 'CRITICO'
           when current_date - l.fecha_tostado >= app.parametro_int('dias_frescura_aviso', 45)
             then 'AVISO'
           else 'FRESCO'
         end as frescura,
         coalesce((select sum(s.cantidad) from saldos s where s.lote_id = l.lote_id), 0)
           as stock_total
    from lotes l
    join articulos a on a.sku = l.sku
    join cafes c     on c.cafe_id = a.cafe_id
    left join formatos f on f.formato_id = a.formato_id;

/* Saldo por lote y ubicación, con el nombre legible. La PWA la usa para
   decir «quedan 7 en la furgoneta» sin tener que cruzar nada. */
create view v_saldo_detalle as
  select s.lote_id, s.sku, s.ubicacion_id,
         u.nombre as ubicacion, u.tipo as tipo_ubicacion,
         s.cantidad, s.reservado, s.disponible,
         (la.lote_id is not null) as es_lote_activo
    from saldos s
    join ubicaciones u on u.ubicacion_id = s.ubicacion_id
    left join lote_activo la
      on la.ubicacion_id = s.ubicacion_id
     and la.sku = s.sku
     and la.lote_id = s.lote_id
   where s.cantidad <> 0;

grant select on v_lote_detalle, v_saldo_detalle to authenticated;

-- ╔══ 20260920091200_13_parametros_extra.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  13 · PARÁMETROS DE ETIQUETA Y DE SINCRONIZACIÓN
-- ═══════════════════════════════════════════════════════════════════════════

insert into parametros (clave, valor, descripcion) values
  ('nombre_empresa', 'Mi Tostador',
   'Nombre comercial. Sale impreso en las etiquetas de El Corte Inglés'),
  ('texto_legal_etiqueta', '',
   'Línea pequeña opcional al pie de la etiqueta de venta propia'),
  ('loyverse_ultima_sincronizacion', '',
   'Fecha del último recibo traído de Loyverse. La gestiona sola la consulta periódica'),
  ('loyverse_dias_iniciales', '7',
   'Cuántos días hacia atrás mira la primera consulta a Loyverse')
on conflict (clave) do nothing;

-- ╔══ 20260920091300_14_cola_eventos.sql ══╗

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

-- ╔══ 20260920091400_15_pedidos_canal.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  15 · PEDIDOS QUE LLEGAN DE UN CANAL
--
--  Una venta de mostrador y un pedido web no son lo mismo y no pueden
--  tratarse igual:
--
--    Mostrador → el cliente se lleva el café. Sale del stock y se acabó.
--    Web       → hay un hueco entre que se paga y que se envía. Durante ese
--                hueco la mercancía sigue en el almacén, pero ya no es
--                vendible por otro canal.
--
--  De ahí la reserva: confirmar compromete, servir descuenta. Sin eso, el
--  mismo último paquete se puede vender por la web y en un mercado el mismo
--  sábado, y uno de los dos clientes se queda sin café.
-- ═══════════════════════════════════════════════════════════════════════════

/* Datos propios de cada canal para el mapeo: en WooCommerce hace falta saber
   si un código es un producto simple o una variación, y de qué producto
   cuelga, porque la API para actualizar el stock es distinta. */
alter table mapeo_articulos add column if not exists datos jsonb not null default '{}'::jsonb;

/* Marca de lo último publicado en cada canal, para no reescribir en el
   sistema ajeno un stock que no ha cambiado. Con 20-30 referencias no es un
   problema de rendimiento: es no llenar el registro de cambios de la tienda
   con ruido que oculte los cambios de verdad. */
create table stock_publicado (
  canal        text not null check (canal in ('woocommerce', 'loyverse')),
  sku          text not null references articulos (sku) on update cascade,
  cantidad     numeric(14,3) not null,
  publicado_en timestamptz not null default now(),
  primary key (canal, sku)
);

grant select on stock_publicado to authenticated;


/* ─────────────────────────── Alta del pedido ─────────────────────────── */

create or replace function registrar_pedido_canal(
  p_operacion_id uuid,
  p_ubicacion_id text,
  p_lineas       jsonb,   -- [{"sku":…, "cantidad":…, "precio_unit":…}]
  p_canal        text,
  p_origen       text,
  p_origen_id    text,
  p_cliente_id   uuid default null,
  p_documento_fiscal text default null,
  p_documento_fiscal_sistema text default null,
  p_forma_pago   text default null,
  p_ocurrido_en  timestamptz default now(),
  p_nota         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido   uuid;
  v_numero   text;
  v_linea    uuid;
  v_precio   numeric;
  v_importe  numeric;
  v_base     numeric := 0;
  v_iva      numeric := app.parametro_int('iva_por_defecto', 21);
  v_asig     jsonb;
  v_falta    numeric;
  v_reservas jsonb := '[]'::jsonb;
  v_incid    jsonb := '[]'::jsonb;
  l          record;
  a          record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para registrar un pedido.'
      using errcode = 'insufficient_privilege';
  end if;

  if not app.abrir_operacion(p_operacion_id, 'RESERVA', p_origen, p_origen_id,
                             null, p_ocurrido_en,
                             jsonb_build_object('lineas', p_lineas,
                                                'canal', p_canal,
                                                'ubicacion_id', p_ubicacion_id,
                                                'cliente_id', p_cliente_id,
                                                'forma_pago', p_forma_pago,
                                                'documento_fiscal', p_documento_fiscal,
                                                'documento_fiscal_sistema',
                                                  p_documento_fiscal_sistema), p_nota) then
    return jsonb_build_object(
      'idempotente', true,
      'operacion_id', p_operacion_id,
      'pedido_id', (select pedido_id from pedidos
                     where origen = p_origen and origen_id = p_origen_id limit 1));
  end if;

  v_numero := 'PED-' || to_char(p_ocurrido_en, 'YYYY') || '-' ||
              lpad(nextval('pedidos_numero_seq')::text, 5, '0');

  insert into pedidos (pedido_id, numero, operacion_id, cliente_id, canal, ubicacion_id,
                       estado, fecha, origen, origen_id,
                       documento_fiscal, documento_fiscal_sistema,
                       iva_pct, forma_pago, notas)
  values (gen_random_uuid(), v_numero, p_operacion_id, p_cliente_id, p_canal, p_ubicacion_id,
          'CONFIRMADO', (p_ocurrido_en at time zone 'Europe/Madrid')::date,
          p_origen, p_origen_id, p_documento_fiscal, p_documento_fiscal_sistema,
          v_iva, p_forma_pago, p_nota)
  returning pedido_id into v_pedido;

  for l in select * from jsonb_to_recordset(p_lineas)
                    as x(sku text, cantidad numeric, precio_unit numeric, dto_pct numeric)
  loop
    if l.cantidad <= 0 then
      raise exception 'La cantidad de % tiene que ser positiva.', l.sku;
    end if;

    v_precio := coalesce(l.precio_unit, (select precio_venta from precios where sku = l.sku), 0);
    v_importe := round(v_precio * l.cantidad * (1 - coalesce(l.dto_pct, 0) / 100), 2);
    v_base := v_base + v_importe;

    insert into pedido_lineas (pedido_id, sku, cantidad, precio_unit, dto_pct, importe)
    values (v_pedido, l.sku, l.cantidad, v_precio, coalesce(l.dto_pct, 0), v_importe)
    returning linea_id into v_linea;

    -- Se compromete el stock, pero NO sale del libro: la mercancía sigue en
    -- el almacén hasta que se envía.
    v_asig := app.asignar_lotes(p_ubicacion_id, l.sku, l.cantidad);
    v_falta := (v_asig ->> 'faltante')::numeric;

    for a in select * from jsonb_to_recordset(v_asig -> 'asignado')
                       as y(lote_id text, cantidad numeric)
    loop
      insert into reservas (operacion_id, pedido_id, linea_id, sku,
                            lote_id, ubicacion_id, cantidad)
      values (p_operacion_id, v_pedido, v_linea, l.sku, a.lote_id, p_ubicacion_id, a.cantidad);

      update saldos set reservado = reservado + a.cantidad, actualizado_en = now()
       where lote_id = a.lote_id and ubicacion_id = p_ubicacion_id;

      v_reservas := v_reservas || jsonb_build_array(
        jsonb_build_object('lote_id', a.lote_id, 'cantidad', a.cantidad));
    end loop;

    -- El pedido ya está pagado en la tienda: negarse no devuelve el café al
    -- estante. Se reserva lo que hay y la diferencia va a conciliación, que
    -- es donde alguien puede decidir si se envía tarde o se reembolsa.
    if v_falta > 0 then
      v_incid := v_incid || jsonb_build_array(app.abrir_incidencia(
        'STOCK_INSUFICIENTE', p_origen, p_origen_id,
        jsonb_build_object('sku', l.sku, 'pedida', l.cantidad, 'reservada', l.cantidad - v_falta,
                           'faltante', v_falta, 'ubicacion', p_ubicacion_id),
        p_operacion_id, null));
    end if;
  end loop;

  update pedidos
     set base  = round(v_base / (1 + v_iva / 100), 2),
         iva   = round(v_base - v_base / (1 + v_iva / 100), 2),
         total = round(v_base, 2)
   where pedido_id = v_pedido;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'pedido_id', v_pedido,
                            'numero', v_numero,
                            'reservas', v_reservas,
                            'incidencias', v_incid);
end;
$$;


/* ─────────────────────────── Servir el pedido ───────────────────────────
   Se reemplaza la versión de la migración 06 para que pueda dejar constancia
   del canal y del identificador de origen. Hace falta para que una devolución
   posterior encuentre de qué lotes salió la mercancía.
   ──────────────────────────────────────────────────────────────── */

drop function if exists servir_reservas_pedido(uuid, uuid, uuid, timestamptz);

create or replace function servir_reservas_pedido(
  p_operacion_id uuid,
  p_pedido_id    uuid,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now(),
  p_origen       text default 'app',
  p_origen_id    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_total  numeric := 0;
  v_origen text;
  v_ref    text;
  r        record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para servir un pedido.'
      using errcode = 'insufficient_privilege';
  end if;

  -- Se guarda el pedido en términos del CANAL, no por su identificador
  -- interno. Al reproducir el histórico sobre una base vacía los uuid son
  -- otros, y sin esta referencia el envío no se podría volver a casar con
  -- su pedido.
  select origen, origen_id into v_origen, v_ref
    from pedidos where pedido_id = p_pedido_id;

  if not app.abrir_operacion(p_operacion_id, 'VENTA', p_origen, p_origen_id,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id,
                                                'desde', 'reservas',
                                                'pedido_origen', v_origen,
                                                'pedido_origen_id', v_ref), null) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for r in select * from reservas
            where pedido_id = p_pedido_id and estado = 'ACTIVA'
            order by reserva_id
  loop
    -- Primero se suelta la reserva y después se anota la salida. En el otro
    -- orden, la restricción reservado <= cantidad rechazaría el movimiento.
    update saldos set reservado = reservado - r.cantidad, actualizado_en = now()
     where lote_id = r.lote_id and ubicacion_id = r.ubicacion_id;

    perform app.anotar(p_operacion_id, r.lote_id, r.ubicacion_id, -r.cantidad, p_ocurrido_en);

    update reservas set estado = 'SERVIDA', cerrado_en = now()
     where reserva_id = r.reserva_id;

    update pedido_lineas set servidas = servidas + r.cantidad
     where linea_id = r.linea_id;

    v_total := v_total + r.cantidad;
  end loop;

  update pedidos set estado = 'SERVIDO' where pedido_id = p_pedido_id;

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id,
                            'unidades', v_total);
end;
$$;

/* Busca el pedido que creó un canal. Los conectores trabajan con el
   identificador del sistema de origen, no con el nuestro. */
create or replace function pedido_de_canal(p_origen text, p_origen_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse.' using errcode = 'insufficient_privilege';
  end if;

  select jsonb_build_object(
           'pedido_id', p.pedido_id, 'numero', p.numero, 'estado', p.estado,
           'ubicacion_id', p.ubicacion_id,
           'reservas_activas', (select count(*) from reservas r
                                 where r.pedido_id = p.pedido_id and r.estado = 'ACTIVA'),
           'servidas', (select coalesce(sum(servidas), 0) from pedido_lineas
                         where pedido_id = p.pedido_id))
    into v
    from pedidos p
   where p.origen = p_origen and p.origen_id = p_origen_id;

  return v;
end;
$$;

grant execute on function
  registrar_pedido_canal(uuid, text, jsonb, text, text, text, uuid, text, text, text, timestamptz, text),
  servir_reservas_pedido(uuid, uuid, uuid, timestamptz, text, text),
  pedido_de_canal(text, text)
to authenticated;


/* Liberar también deja la referencia del canal, por la misma razón que
   servir: al reproducir el histórico hay que saber qué pedido era. */
create or replace function liberar_reservas_pedido(
  p_operacion_id uuid,
  p_pedido_id    uuid,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_n      int := 0;
  v_origen text;
  v_ref    text;
  r        record;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para liberar reservas.'
      using errcode = 'insufficient_privilege';
  end if;

  select origen, origen_id into v_origen, v_ref
    from pedidos where pedido_id = p_pedido_id;

  if not app.abrir_operacion(p_operacion_id, 'LIBERACION', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id,
                                                'pedido_origen', v_origen,
                                                'pedido_origen_id', v_ref), null) then
    return jsonb_build_object('idempotente', true, 'operacion_id', p_operacion_id);
  end if;

  for r in select * from reservas where pedido_id = p_pedido_id and estado = 'ACTIVA'
  loop
    update saldos set reservado = reservado - r.cantidad, actualizado_en = now()
     where lote_id = r.lote_id and ubicacion_id = r.ubicacion_id;
    update reservas set estado = 'LIBERADA', cerrado_en = now()
     where reserva_id = r.reserva_id;
    v_n := v_n + 1;
  end loop;

  update pedidos set estado = 'CANCELADO'
   where pedido_id = p_pedido_id and estado in ('BORRADOR', 'CONFIRMADO');

  return jsonb_build_object('idempotente', false,
                            'operacion_id', p_operacion_id, 'liberadas', v_n);
end;
$$;

-- ╔══ 20260920091500_16_hosteleria.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  16 · HOSTELERÍA · PEDIDOS POR ENLACE
--
--  Bares y cafeterías piden por WhatsApp. De las dos opciones que se
--  plantearon, esta es la recomendada: un formulario que se manda por enlace,
--  en vez de la Cloud API de WhatsApp.
--
--  Por qué:
--    · no hay coste por conversación ni aprobación de Meta que esperar;
--    · no hay que interpretar lenguaje natural, que es donde se equivocaría:
--      «ponme 3 de la mezcla» no dice el formato, y «lo de siempre» no dice
--      nada. Un desplegable no se equivoca;
--    · el cliente no instala nada: abre un enlace y pide.
--
--  Cada cliente tiene SU enlace, que se puede revocar sin afectar a los demás.
--  El enlace es la credencial, así que no se puede adivinar y se puede
--  cambiar en un segundo si acaba donde no debe.
-- ═══════════════════════════════════════════════════════════════════════════

alter table clientes
  add column if not exists token_pedido text,
  add column if not exists token_creado_en timestamptz;

create unique index if not exists clientes_token_unico
  on clientes (token_pedido) where token_pedido is not null;

comment on column clientes.token_pedido is
  'Credencial del enlace de pedido. Quien la tiene puede pedir en nombre de '
  'este cliente, así que se genera al azar y se puede revocar.';

insert into parametros (clave, valor, descripcion) values
  ('hosteleria_ubicacion', 'ALMACEN',
   'Ubicación desde la que se reservan los pedidos de hostelería'),
  ('hosteleria_pedidos_max_hora', '5',
   'Pedidos que admite un mismo enlace por hora. Freno a envíos repetidos por error'),
  ('hosteleria_whatsapp', '',
   'Teléfono del tostador, en formato internacional sin signos, para el botón de avisar'),
  ('hosteleria_mensaje', 'Gracias por tu pedido. Te avisamos en cuanto salga.',
   'Mensaje que ve el cliente al terminar')
on conflict (clave) do nothing;


/* ─────────────────────────── Gestión del enlace ─────────────────────────── */

create or replace function generar_enlace_pedido(p_cliente_id uuid)
returns text
language plpgsql
volatile
security definer
-- `extensions` porque gen_random_bytes también es de pgcrypto, y ahí es donde
-- vive en Supabase. Ver migración 01.
set search_path = public, extensions, pg_temp
as $$
declare
  v_token text;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para generar un enlace.'
      using errcode = 'insufficient_privilege';
  end if;

  -- 32 caracteres al azar: no se adivina probando.
  v_token := encode(gen_random_bytes(16), 'hex');

  update clientes
     set token_pedido = v_token, token_creado_en = now()
   where cliente_id = p_cliente_id and activo;

  if not found then
    raise exception 'Ese cliente no existe o está dado de baja.';
  end if;

  return v_token;
end;
$$;

create or replace function revocar_enlace_pedido(p_cliente_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para revocar un enlace.'
      using errcode = 'insufficient_privilege';
  end if;

  update clientes set token_pedido = null, token_creado_en = null
   where cliente_id = p_cliente_id;

  return found;
end;
$$;


/* ─────────────────────────── Lo que ve el cliente ───────────────────────────
   Se devuelve el catálogo con SU precio, ya con su descuento habitual
   aplicado. El cliente no ve costes, ni márgenes, ni stock de otros sitios:
   solo lo que puede pedir y a cuánto le sale.
   ──────────────────────────────────────────────────────────────── */

create or replace function catalogo_pedido(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_cliente  record;
  v_ubicacion text := app.parametro('hosteleria_ubicacion', 'ALMACEN');
  v_articulos jsonb;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then
    return null;
  end if;

  select cliente_id, nombre, descuento_pct into v_cliente
    from clientes where token_pedido = p_token and activo;

  if v_cliente.cliente_id is null then
    -- Enlace revocado, cliente de baja o token inventado: la misma respuesta
    -- para los tres, para no decirle a nadie cuál de las tres es.
    return null;
  end if;

  select coalesce(jsonb_agg(x order by x ->> 'cafe', x ->> 'formato'), '[]'::jsonb)
    into v_articulos
    from (
      select jsonb_build_object(
               'sku', a.sku,
               'cafe', c.nombre,
               'origen', c.origen,
               'perfil_tueste', c.perfil_tueste,
               'formato', f.nombre,
               'gramos', f.gramos,
               'molienda', f.molienda,
               'precio', round(coalesce(pr.precio_venta, 0)
                               * (1 - v_cliente.descuento_pct / 100), 2),
               'disponible', coalesce((select sum(s.disponible) from saldos s
                                        where s.sku = a.sku
                                          and s.ubicacion_id = v_ubicacion), 0)
             ) as x
        from articulos a
        join cafes c    on c.cafe_id = a.cafe_id
        join formatos f on f.formato_id = a.formato_id
        left join precios pr on pr.sku = a.sku
       where a.clase = 'PAQUETE' and a.activo and c.activo and f.activo
         and coalesce(pr.precio_venta, 0) > 0
    ) z;

  return jsonb_build_object(
    'cliente', jsonb_build_object('nombre', v_cliente.nombre,
                                  'descuento_pct', v_cliente.descuento_pct),
    'articulos', v_articulos,
    'mensaje_final', app.parametro('hosteleria_mensaje', ''),
    'whatsapp', app.parametro('hosteleria_whatsapp', ''));
end;
$$;


/* ─────────────────────────── Alta del pedido ─────────────────────────── */

create or replace function crear_pedido_hosteleria(
  p_operacion_id uuid,
  p_token        text,
  p_lineas       jsonb,   -- [{"sku":…, "cantidad":…}]
  p_nota         text default null,
  p_ocurrido_en  timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cliente   uuid;
  v_nombre    text;
  v_descuento numeric;
  v_ubicacion text := app.parametro('hosteleria_ubicacion', 'ALMACEN');
  v_maximo    int  := app.parametro_int('hosteleria_pedidos_max_hora', 5);
  v_recientes int;
  v_lineas    jsonb;
  r           jsonb;
begin
  select cliente_id, nombre, descuento_pct into v_cliente, v_nombre, v_descuento
    from clientes where token_pedido = p_token and activo;

  if v_cliente is null then
    raise exception 'El enlace no es válido o ha sido revocado.'
      using errcode = 'insufficient_privilege';
  end if;

  if jsonb_array_length(coalesce(p_lineas, '[]'::jsonb)) = 0 then
    raise exception 'El pedido está vacío.';
  end if;

  -- Freno a los envíos repetidos. No es tanto contra un ataque como contra
  -- el doble clic y el «no sé si se ha enviado» que lo manda tres veces.
  select count(*) into v_recientes
    from pedidos
   where cliente_id = v_cliente
     and origen = 'app'
     and canal = 'Hostelería'
     and creado_en > now() - interval '1 hour';

  if v_recientes >= v_maximo then
    raise exception 'Se han recibido % pedidos de este enlace en la última hora. '
                    'Si es correcto, llámanos y lo tramitamos.', v_recientes;
  end if;

  -- El precio lo pone el servidor, nunca el formulario: el cliente podría
  -- mandar el que quisiera.
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', l.sku,
           'cantidad', l.cantidad,
           'precio_unit', round(coalesce(pr.precio_venta, 0)
                                * (1 - v_descuento / 100), 2))), '[]'::jsonb)
    into v_lineas
    from jsonb_to_recordset(p_lineas) as l(sku text, cantidad numeric)
    join articulos a on a.sku = l.sku and a.clase = 'PAQUETE' and a.activo
    left join precios pr on pr.sku = l.sku
   where l.cantidad > 0 and l.cantidad = trunc(l.cantidad) and l.cantidad <= 999;

  if jsonb_array_length(v_lineas) = 0 then
    raise exception 'Ninguna de las líneas del pedido es válida.';
  end if;

  r := registrar_pedido_canal(
         p_operacion_id, v_ubicacion, v_lineas, 'Hostelería',
         'app', 'host-' || p_operacion_id::text, v_cliente,
         null, null, null, p_ocurrido_en,
         coalesce(nullif(btrim(p_nota), ''), 'Pedido por enlace'));

  return jsonb_build_object(
    'pedido_id', r ->> 'pedido_id',
    'numero', r ->> 'numero',
    'cliente', v_nombre,
    'idempotente', r -> 'idempotente');
end;
$$;

-- Estas funciones las llama el servidor con perfil SISTEMA; el enlace es la
-- credencial y se comprueba dentro. No se conceden a `anon`: el navegador del
-- cliente no habla con la base, habla con nuestro servidor.
grant execute on function
  generar_enlace_pedido(uuid), revocar_enlace_pedido(uuid),
  catalogo_pedido(text), crear_pedido_hosteleria(uuid, text, jsonb, text, timestamptz)
to authenticated;

-- ╔══ 20260920091600_17_endurecimiento.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  17 · ENDURECIMIENTO TRAS LA REVISIÓN DE SEGURIDAD
--
--  Tres correcciones. La primera es la importante.
-- ═══════════════════════════════════════════════════════════════════════════


/* ═══════════════════════════════════════════════════════════════════════
   A · FUERZA BRUTA CONTRA EL PIN                                  (GRAVE)

   Un PIN de cuatro cifras son diez mil combinaciones. La aplicación está en
   internet, la lista de usuarios era pública y no había ningún freno: probar
   las diez mil era cuestión de minutos, y con ellas se entraba como
   administrador.

   Un PIN corto es la decisión correcta para trabajar con las manos sucias en
   un mercado. Lo que faltaba no era un PIN más largo, sino que probar salga
   caro.
   ═══════════════════════════════════════════════════════════════════════ */

create table intentos_acceso (
  usuario_id      uuid primary key references usuarios (usuario_id) on delete cascade,
  fallos          integer not null default 0 check (fallos >= 0),
  bloqueado_hasta timestamptz,
  ultimo_fallo    timestamptz
);

comment on table intentos_acceso is
  'Freno a la fuerza bruta. No se borra al acertar: se pone a cero, para que '
  'el histórico de bloqueos siga siendo consultable.';

alter table intentos_acceso enable row level security;
alter table intentos_acceso force row level security;
revoke all on intentos_acceso from anon, authenticated;
grant select on intentos_acceso to authenticated;
create policy leer_intentos on intentos_acceso
  for select to authenticated using (app.tiene_nivel('ADMIN'));

insert into parametros (clave, valor, descripcion) values
  ('acceso_fallos_antes_de_bloquear', '5',
   'Intentos fallidos seguidos antes de empezar a bloquear el acceso'),
  ('acceso_bloqueo_segundos', '60',
   'Segundos de bloqueo tras superar los fallos. Se duplica con cada tanda, hasta una hora')
on conflict (clave) do nothing;

/** Cuánto hay que esperar según los fallos acumulados. Crece deprisa: a los
    veinte fallos ya son horas, y probar diez mil PIN deja de ser viable. */
create or replace function app.espera_acceso(p_fallos int)
returns interval
language sql
stable
as $$
  select case
    when p_fallos < app.parametro_int('acceso_fallos_antes_de_bloquear', 5) then interval '0'
    else least(
      app.parametro_int('acceso_bloqueo_segundos', 60)
        * power(2, (p_fallos - app.parametro_int('acceso_fallos_antes_de_bloquear', 5)) / 3),
      3600)::int * interval '1 second'
  end;
$$;

create or replace function acceder(p_usuario_id uuid, p_pin text)
returns table (usuario_id uuid, nombre text, rol rol_usuario)
language plpgsql
volatile                       -- ahora escribe: lleva la cuenta de los fallos
security definer
-- `extensions` porque ahí vive pgcrypto en Supabase. Ver migración 01.
set search_path = public, extensions, pg_temp
as $$
declare
  v_bloqueado timestamptz;
  v_fallos    int;
  v_ok        boolean := false;
  v_u         record;
begin
  if p_pin !~ '^[0-9]{4,8}$' then
    return;
  end if;

  -- Se bloquea la fila para que veinte peticiones a la vez no cuenten como
  -- un solo intento. Sin esto, el atacante sortea el freno con concurrencia.
  -- Se nombra la restricción, no la columna: `usuario_id` también es una de
  -- las columnas que devuelve esta función, y PL/pgSQL no sabría a cuál de
  -- las dos se refiere.
  insert into intentos_acceso (usuario_id) values (p_usuario_id)
  on conflict on constraint intentos_acceso_pkey do nothing;

  select bloqueado_hasta, fallos into v_bloqueado, v_fallos
    from intentos_acceso where intentos_acceso.usuario_id = p_usuario_id
     for update;

  -- Mientras está bloqueado ni se mira el PIN: acertarlo por casualidad
  -- durante el bloqueo tampoco abre.
  if v_bloqueado is not null and v_bloqueado > now() then
    return;
  end if;

  select u.usuario_id, u.nombre, u.rol into v_u
    from usuarios u
   where u.usuario_id = p_usuario_id
     and u.activo
     and u.pin_hash = crypt(p_pin, u.pin_hash);

  v_ok := v_u.usuario_id is not null;

  if v_ok then
    update intentos_acceso
       set fallos = 0, bloqueado_hasta = null
     where intentos_acceso.usuario_id = p_usuario_id;

    return query select v_u.usuario_id, v_u.nombre, v_u.rol;
    -- `return query` NO termina la función: sin este `return`, un acceso
    -- correcto seguiría hasta la rama de fallo de abajo y se contaría como
    -- error. Un usuario legítimo acabaría bloqueándose solo.
    return;
  end if;

  update intentos_acceso
     set fallos = intentos_acceso.fallos + 1,
         ultimo_fallo = now(),
         bloqueado_hasta = case
           when app.espera_acceso(intentos_acceso.fallos + 1) > interval '0'
             then now() + app.espera_acceso(intentos_acceso.fallos + 1)
           else null
         end
   where intentos_acceso.usuario_id = p_usuario_id;

  return;
end;
$$;

comment on function acceder(uuid, text) is
  'Comprueba el PIN llevando la cuenta de los fallos. No distingue usuario '
  'inexistente, PIN erróneo ni cuenta bloqueada: las tres devuelven lo mismo.';

/** Cuánto queda de bloqueo, para poder decírselo a quien está esperando sin
    entender por qué no entra. No dice nada que el atacante no sepa ya. */
create or replace function espera_de_acceso(p_usuario_id uuid)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select greatest(0, ceil(extract(epoch from (bloqueado_hasta - now())))::int)
    from intentos_acceso
   where usuario_id = p_usuario_id and bloqueado_hasta > now();
$$;

/** Desbloquear a mano: alguien se ha equivocado cinco veces y está esperando. */
create or replace function desbloquear_acceso(p_usuario_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('ADMIN') then
    raise exception 'Solo un administrador puede desbloquear un acceso.'
      using errcode = 'insufficient_privilege';
  end if;
  update intentos_acceso set fallos = 0, bloqueado_hasta = null
   where usuario_id = p_usuario_id;
  return found;
end;
$$;

-- Cambia la forma de lo que devuelve, así que hay que retirar la anterior.
drop function if exists usuarios_para_acceso();

/* La lista de acceso deja de decir quién es administrador. Es lo primero que
   mira quien quiere entrar: saber a quién atacar le ahorraba la mitad del
   trabajo. El nombre hace falta para el desplegable; el rol, no. */
create or replace function usuarios_para_acceso()
returns table (usuario_id uuid, nombre text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select usuario_id, nombre from usuarios where activo order by nombre;
$$;

grant execute on function
  acceder(uuid, text), espera_de_acceso(uuid), usuarios_para_acceso()
to anon, authenticated;
grant execute on function desbloquear_acceso(uuid) to authenticated;


/* ═══════════════════════════════════════════════════════════════════════
   B · `stock_publicado` SIN RLS Y SIN PODER ESCRIBIRSE         (FUNCIONAL)

   Se creó después de la migración de permisos, así que se quedó fuera: era
   la única tabla sin RLS, y el conector de WooCommerce no podía escribirla.
   La publicación de stock habría fallado en cada vuelta.
   ═══════════════════════════════════════════════════════════════════════ */

alter table stock_publicado enable row level security;
alter table stock_publicado force row level security;
revoke all on stock_publicado from anon, authenticated;
grant select on stock_publicado to authenticated;

create policy leer_stock_publicado on stock_publicado
  for select to authenticated using (app.tiene_nivel('OPERARIO'));

/* Se escribe por función, como el resto: la tabla no recibe permiso directo. */
create or replace function anotar_stock_publicado(p_canal text, p_filas jsonb)
returns integer
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_n int;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para anotar el stock publicado.'
      using errcode = 'insufficient_privilege';
  end if;

  insert into stock_publicado (canal, sku, cantidad, publicado_en)
  select p_canal, f.sku, f.cantidad, now()
    from jsonb_to_recordset(p_filas) as f(sku text, cantidad numeric)
  on conflict (canal, sku) do update
    set cantidad = excluded.cantidad, publicado_en = excluded.publicado_en;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

grant execute on function anotar_stock_publicado(text, jsonb) to authenticated;


/* ═══════════════════════════════════════════════════════════════════════
   C · EL ENLACE DE PEDIDO ERA LEGIBLE POR CUALQUIER OPERARIO        (MEDIA)

   `clientes.token_pedido` es la credencial con la que un bar hace pedidos.
   La política de lectura de clientes la abría a cualquiera identificado.
   Que las rutas comprobaran el perfil no basta: la capa que manda es esta.

   Se pasa a permiso por columna: la credencial sale solo por las funciones
   que la gestionan, y solo para un gestor.
   ═══════════════════════════════════════════════════════════════════════ */

revoke select, update on clientes from authenticated;

grant select (cliente_id, nombre, tipo, nif, email, telefono, direccion, cp,
              poblacion, provincia, pais, descuento_pct, alta, activo, notas,
              creado_en)
  on clientes to authenticated;

-- El ciclo de vida del enlace vive en generar/revocar, no en un UPDATE suelto.
grant update (nombre, tipo, nif, email, telefono, direccion, cp, poblacion,
              provincia, pais, descuento_pct, alta, activo, notas)
  on clientes to authenticated;

create or replace function clientes_con_enlace()
returns table (cliente_id uuid, nombre text, tipo text, telefono text,
               descuento_pct numeric, token_creado_en timestamptz, token_pedido text)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Se necesita perfil de gestor para ver los enlaces de pedido.'
      using errcode = 'insufficient_privilege';
  end if;

  return query
    select c.cliente_id, c.nombre, c.tipo, c.telefono,
           c.descuento_pct, c.token_creado_en, c.token_pedido
      from clientes c
     where c.activo
     order by c.nombre;
end;
$$;

grant execute on function clientes_con_enlace() to authenticated;

-- ╔══ 20260920091700_18_administracion.sql ══╗

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

-- ╔══ 20260920091800_19_bot.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  19 · BOT DE CONSULTA
--
--  Preguntar por el negocio desde el móvil sin abrir la aplicación.
--
--  EL PROBLEMA DE FONDO, Y LA DECISIÓN QUE LO RESUELVE
--
--  A un bot le puede escribir cualquiera que dé con él. Si respondiera a
--  quien le hable, un cliente podría preguntar cuánto stock hay, qué margen
--  se saca o qué se le vende a El Corte Inglés. Sería una fuga de datos del
--  negocio.
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
  canal       text not null check (canal in ('telegram', 'prueba')),
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
   'Consultas por persona y hora. Freno a un bucle o a un uso desbocado'),
  ('telegram_usuario_bot', '',
   'Nombre del bot en Telegram, sin la arroba. Se usa para el enlace de alta')
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

-- ╔══ 20260920092000_21_bultos.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  21 · PREPARACIÓN Y BULTOS
--
--  Dos cosas distintas que se hacen a la vez y conviene no confundir:
--
--    PREPARAR  → sacar el café del estante. ESO sí toca el inventario: es la
--                salida definitiva, y se anota del lote que realmente se ha
--                cogido, que no tiene por qué ser el que estaba reservado.
--
--    EMPAQUETAR → meterlo en cajas. NO toca el inventario: la mercancía ya
--                 salió. Lo que se guarda es qué lote fue a qué caja, que es
--                 lo que permite avisar al cliente correcto si un lote sale
--                 malo.
--
--  Por eso los bultos no escriben en el libro de movimientos. Si lo hicieran,
--  empaquetar contaría la salida dos veces.
-- ═══════════════════════════════════════════════════════════════════════════

create type estado_bulto as enum ('ABIERTO', 'CERRADO');

create table tipos_caja (
  caja_id      text primary key check (caja_id ~ '^[A-Z0-9_]{1,12}$'),
  nombre       text not null,
  largo_cm     numeric(6,1) not null check (largo_cm > 0),
  ancho_cm     numeric(6,1) not null check (ancho_cm > 0),
  alto_cm      numeric(6,1) not null check (alto_cm  > 0),
  peso_vacio_g integer not null default 0 check (peso_vacio_g >= 0),
  activo       boolean not null default true
);

comment on table tipos_caja is
  'Las cajas que se usan. El peso en vacío hace falta para dar al '
  'transportista el peso del bulto sin pesarlo.';

-- El volumen decide cuál es «la más pequeña que vale».
create table capacidad_caja (
  caja_id      text not null references tipos_caja (caja_id) on update cascade on delete cascade,
  formato_id   text not null references formatos (formato_id) on update cascade on delete cascade,
  unidades_max integer not null check (unidades_max > 0),
  primary key (caja_id, formato_id)
);

comment on table capacidad_caja is
  'Cuántos paquetes de cada formato caben en cada caja. Se mide una vez, '
  'metiéndolos de verdad: calcularlo por volumen da números que no salen.';

create table bultos (
  bulto_id    uuid primary key default gen_random_uuid(),
  pedido_id   uuid not null references pedidos (pedido_id) on delete cascade,
  caja_id     text references tipos_caja (caja_id) on update cascade,
  estado      estado_bulto not null default 'ABIERTO',
  unidades    numeric(14,3) not null default 0,
  peso_g      integer,
  creado_en   timestamptz not null default now(),
  cerrado_en  timestamptz,
  creado_por  uuid references usuarios (usuario_id),
  seguimiento text,

  constraint cerrado_con_fecha
    check ((estado = 'ABIERTO') = (cerrado_en is null))
);

create index bultos_por_pedido on bultos (pedido_id);
create index bultos_abiertos on bultos (estado) where estado = 'ABIERTO';

create table bulto_contenido (
  bulto_id uuid not null references bultos (bulto_id) on delete cascade,
  lote_id  text not null references lotes (lote_id),
  sku      text not null references articulos (sku) on update cascade,
  cantidad numeric(14,3) not null check (cantidad > 0),
  primary key (bulto_id, lote_id)
);

comment on table bulto_contenido is
  'Qué lote fue en qué caja. Es lo que permite, si un lote sale malo, avisar '
  'solo a los clientes que lo recibieron en vez de a todos.';

alter table tipos_caja      enable row level security;
alter table capacidad_caja  enable row level security;
alter table bultos          enable row level security;
alter table bulto_contenido enable row level security;
alter table tipos_caja      force row level security;
alter table capacidad_caja  force row level security;
alter table bultos          force row level security;
alter table bulto_contenido force row level security;

revoke all on tipos_caja, capacidad_caja, bultos, bulto_contenido from anon, authenticated;
grant select on tipos_caja, capacidad_caja, bultos, bulto_contenido to authenticated;
grant insert, update, delete on tipos_caja, capacidad_caja to authenticated;

do $$
declare t text;
begin
  foreach t in array array['tipos_caja','capacidad_caja','bultos','bulto_contenido'] loop
    execute format($p$
      create policy %I on %I for select to authenticated using (app.tiene_nivel('OPERARIO'))
    $p$, 'leer_' || t, t);
  end loop;

  foreach t in array array['tipos_caja','capacidad_caja'] loop
    execute format($p$
      create policy %I on %I for all to authenticated
        using (app.tiene_nivel('GESTOR')) with check (app.tiene_nivel('GESTOR'))
    $p$, 'gestionar_' || t, t);
  end loop;
end $$;


/* ─────────────────────────── Preparar: sacar del estante ───────────────────────────
   Un escaneo, un paquete. Se anota la salida DEL LOTE ESCANEADO, que puede no
   ser el reservado: quien prepara coge lo que tiene delante, y el libro debe
   contar lo que pasó, no lo que estaba previsto.
   ──────────────────────────────────────────────────────────────── */

create or replace function servir_linea_escaneada(
  p_operacion_id uuid,
  p_pedido_id    uuid,
  p_lote_id      text,
  p_cantidad     numeric default 1,
  p_usuario_id   uuid default null,
  p_ocurrido_en  timestamptz default now()
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sku       text;
  v_ubicacion text;
  v_origen    text;
  v_ref       text;
  v_linea     uuid;
  v_pendiente numeric;
  v_resto     numeric;
  v_soltar    numeric;
  r           record;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para preparar un pedido.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_cantidad <= 0 then
    raise exception 'La cantidad tiene que ser positiva.';
  end if;

  select l.sku into v_sku from lotes l where l.lote_id = p_lote_id;
  if v_sku is null then
    raise exception 'El lote % no existe.', p_lote_id using errcode = 'foreign_key_violation';
  end if;

  select p.ubicacion_id, p.origen, p.origen_id into v_ubicacion, v_origen, v_ref
    from pedidos p where p.pedido_id = p_pedido_id;
  if v_ubicacion is null then
    raise exception 'Ese pedido no existe.';
  end if;

  -- La idempotencia se comprueba ANTES de validar nada más, y no después.
  --
  -- La cola offline reenvía lo que ya subió: si primero se validara «¿queda
  -- pendiente?», el reenvío de un escaneo ya contabilizado daría «solo quedan
  -- 1 por servir» y el operario vería un error por algo que salió bien. Aquí
  -- el reenvío tiene que ser un no-op silencioso.
  if not app.abrir_operacion(p_operacion_id, 'VENTA', 'app', null,
                             p_usuario_id, p_ocurrido_en,
                             jsonb_build_object('pedido_id', p_pedido_id,
                                                'desde', 'escaner',
                                                'lote_id', p_lote_id,
                                                'cantidad', p_cantidad,
                                                'pedido_origen', v_origen,
                                                'pedido_origen_id', v_ref), null) then
    return jsonb_build_object(
      'idempotente', true, 'operacion_id', p_operacion_id, 'sku', v_sku,
      'pendiente', (select coalesce(sum(cantidad - servidas), 0)
                      from pedido_lineas where pedido_id = p_pedido_id),
      'completo', not exists (select 1 from pedido_lineas
                               where pedido_id = p_pedido_id and cantidad > servidas));
  end if;

  select pl.linea_id, pl.cantidad - pl.servidas
    into v_linea, v_pendiente
    from pedido_lineas pl
   where pl.pedido_id = p_pedido_id and pl.sku = v_sku and pl.cantidad > pl.servidas
   order by pl.linea_id
   limit 1;

  if v_linea is null then
    -- Es el error que más se comete preparando: coger la bolsa de al lado.
    raise exception 'Ese lote no es de este pedido, o ya está todo servido.'
      using hint = 'no_pertenece';
  end if;
  if p_cantidad > v_pendiente then
    raise exception 'De % solo quedan % por servir.', v_sku, v_pendiente
      using hint = 'de_mas';
  end if;

  -- Se suelta reserva de ese artículo por la cantidad servida, del lote que
  -- sea: lo reservado era una promesa sobre el artículo, y se cumple con el
  -- paquete que se ha cogido.
  v_resto := p_cantidad;
  for r in select * from reservas
            where pedido_id = p_pedido_id and sku = v_sku and estado = 'ACTIVA'
            order by reserva_id
  loop
    exit when v_resto <= 0;
    v_soltar := least(r.cantidad, v_resto);

    update saldos set reservado = reservado - v_soltar, actualizado_en = now()
     where lote_id = r.lote_id and ubicacion_id = r.ubicacion_id;

    if v_soltar = r.cantidad then
      update reservas set estado = 'SERVIDA', cerrado_en = now() where reserva_id = r.reserva_id;
    else
      update reservas set cantidad = cantidad - v_soltar where reserva_id = r.reserva_id;
    end if;

    v_resto := v_resto - v_soltar;
  end loop;

  perform app.anotar(p_operacion_id, p_lote_id, v_ubicacion, -p_cantidad, p_ocurrido_en);

  update pedido_lineas set servidas = servidas + p_cantidad where linea_id = v_linea;

  update pedidos set estado = 'PREPARANDO'
   where pedido_id = p_pedido_id and estado = 'CONFIRMADO';

  -- Cuando no queda nada pendiente, el pedido está servido.
  if not exists (select 1 from pedido_lineas
                  where pedido_id = p_pedido_id and cantidad > servidas) then
    update pedidos set estado = 'SERVIDO' where pedido_id = p_pedido_id;
  end if;

  return jsonb_build_object(
    'idempotente', false, 'operacion_id', p_operacion_id, 'sku', v_sku,
    'pendiente', (select coalesce(sum(cantidad - servidas), 0)
                    from pedido_lineas where pedido_id = p_pedido_id),
    'completo', not exists (select 1 from pedido_lineas
                             where pedido_id = p_pedido_id and cantidad > servidas));
end;
$$;


/* ─────────────────────────── Empaquetar ─────────────────────────── */

create or replace function sugerir_caja(p_pedido_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse.' using errcode = 'insufficient_privilege';
  end if;

  -- Lo que falta por meter en caja: lo del pedido menos lo ya empaquetado.
  with pendiente as (
    select pl.sku, a.formato_id,
           sum(pl.cantidad) - coalesce((
             select sum(bc.cantidad) from bulto_contenido bc
               join bultos b on b.bulto_id = bc.bulto_id
              where b.pedido_id = p_pedido_id and bc.sku = pl.sku), 0) as uds
      from pedido_lineas pl
      join articulos a on a.sku = pl.sku
     where pl.pedido_id = p_pedido_id
     group by pl.sku, a.formato_id
  ),
  -- Una caja vale si cubre TODOS los formatos pendientes. Se mira formato a
  -- formato porque en 250 g caben muchos más que en 1 kg.
  validas as (
    select c.caja_id, c.nombre,
           c.largo_cm * c.ancho_cm * c.alto_cm as volumen
      from tipos_caja c
     where c.activo
       and not exists (
         select 1 from pendiente p
          where p.uds > 0
            and coalesce((select cc.unidades_max from capacidad_caja cc
                           where cc.caja_id = c.caja_id
                             and cc.formato_id = p.formato_id), 0) < p.uds)
  )
  select jsonb_build_object(
           'caja_id', v2.caja_id, 'nombre', v2.nombre,
           'pendiente', (select coalesce(sum(uds), 0) from pendiente where uds > 0))
    into v
    from (select * from validas order by volumen limit 1) v2;

  return coalesce(v, jsonb_build_object(
    'caja_id', null,
    'nota', 'No hay ninguna caja donde quepa todo de una vez: hará falta más de un bulto.',
    'pendiente', (select coalesce(sum(uds), 0)
                    from (select sum(pl.cantidad) - coalesce((
                            select sum(bc.cantidad) from bulto_contenido bc
                              join bultos b on b.bulto_id = bc.bulto_id
                             where b.pedido_id = p_pedido_id and bc.sku = pl.sku), 0) as uds
                            from pedido_lineas pl
                           where pl.pedido_id = p_pedido_id
                           group by pl.sku) z where uds > 0)));
end;
$$;

create or replace function crear_bulto(p_pedido_id uuid, p_caja_id text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse para abrir un bulto.'
      using errcode = 'insufficient_privilege';
  end if;

  insert into bultos (pedido_id, caja_id, creado_por)
  values (p_pedido_id, p_caja_id, app.usuario_actual())
  returning bulto_id into v_id;

  return jsonb_build_object('bulto_id', v_id);
end;
$$;

create or replace function anadir_a_bulto(
  p_bulto_id uuid, p_lote_id text, p_cantidad numeric default 1
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_pedido    uuid;
  v_caja      text;
  v_estado    estado_bulto;
  v_sku       text;
  v_formato   text;
  v_max       integer;
  v_ya        numeric;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse.' using errcode = 'insufficient_privilege';
  end if;

  select pedido_id, caja_id, estado into v_pedido, v_caja, v_estado
    from bultos where bulto_id = p_bulto_id;
  if v_pedido is null then
    raise exception 'Ese bulto no existe.';
  end if;
  if v_estado = 'CERRADO' then
    raise exception 'Ese bulto ya está cerrado. Abre otro.';
  end if;

  select l.sku, a.formato_id into v_sku, v_formato
    from lotes l join articulos a on a.sku = l.sku
   where l.lote_id = p_lote_id;
  if v_sku is null then
    raise exception 'El lote % no existe.', p_lote_id;
  end if;

  if not exists (select 1 from pedido_lineas
                  where pedido_id = v_pedido and sku = v_sku) then
    raise exception 'Ese lote no es de este pedido.' using hint = 'no_pertenece';
  end if;

  -- Si la caja tiene capacidad declarada, se avisa antes de que no cierre.
  if v_caja is not null and v_formato is not null then
    select unidades_max into v_max
      from capacidad_caja where caja_id = v_caja and formato_id = v_formato;

    if v_max is not null then
      select coalesce(sum(bc.cantidad), 0) into v_ya
        from bulto_contenido bc join lotes l on l.lote_id = bc.lote_id
        join articulos a on a.sku = l.sku
       where bc.bulto_id = p_bulto_id and a.formato_id = v_formato;

      if v_ya + p_cantidad > v_max then
        raise exception 'En esa caja solo caben % de ese formato, y ya lleva %.',
          v_max, v_ya using hint = 'no_cabe';
      end if;
    end if;
  end if;

  insert into bulto_contenido (bulto_id, lote_id, sku, cantidad)
  values (p_bulto_id, p_lote_id, v_sku, p_cantidad)
  on conflict (bulto_id, lote_id) do update
    set cantidad = bulto_contenido.cantidad + excluded.cantidad;

  update bultos set unidades = (
    select coalesce(sum(cantidad), 0) from bulto_contenido where bulto_id = p_bulto_id
  ) where bulto_id = p_bulto_id;

  return jsonb_build_object(
    'bulto_id', p_bulto_id, 'sku', v_sku,
    'unidades', (select unidades from bultos where bulto_id = p_bulto_id));
end;
$$;

create or replace function cerrar_bulto(p_bulto_id uuid, p_seguimiento text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_peso integer;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse.' using errcode = 'insufficient_privilege';
  end if;

  if not exists (select 1 from bulto_contenido where bulto_id = p_bulto_id) then
    raise exception 'El bulto está vacío.';
  end if;

  -- Peso estimado: lo que pesa el café más la caja vacía. No sustituye a la
  -- báscula, pero sirve para dar el dato al transportista.
  select coalesce(c.peso_vacio_g, 0) + coalesce(sum(bc.cantidad * f.gramos), 0)
    into v_peso
    from bultos b
    left join tipos_caja c on c.caja_id = b.caja_id
    left join bulto_contenido bc on bc.bulto_id = b.bulto_id
    left join articulos a on a.sku = bc.sku
    left join formatos f on f.formato_id = a.formato_id
   where b.bulto_id = p_bulto_id
   group by c.peso_vacio_g;

  update bultos
     set estado = 'CERRADO', cerrado_en = now(), peso_g = v_peso,
         seguimiento = coalesce(p_seguimiento, seguimiento)
   where bulto_id = p_bulto_id and estado = 'ABIERTO';

  if not found then
    raise exception 'Ese bulto no existe o ya estaba cerrado.';
  end if;

  return jsonb_build_object('bulto_id', p_bulto_id, 'peso_g', v_peso);
end;
$$;

/** Los bultos de un pedido, con su contenido. Para el albarán y la pantalla. */
create or replace function bultos_de_pedido(p_pedido_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse.' using errcode = 'insufficient_privilege';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'bulto_id', b.bulto_id, 'caja_id', b.caja_id, 'estado', b.estado,
             'unidades', b.unidades, 'peso_g', b.peso_g, 'seguimiento', b.seguimiento,
             'creado_en', b.creado_en,
             'contenido', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'lote_id', bc.lote_id, 'sku', bc.sku, 'cantidad', bc.cantidad)
                      order by bc.lote_id)
                 from bulto_contenido bc where bc.bulto_id = b.bulto_id), '[]'::jsonb))
           order by b.creado_en)
      from bultos b where b.pedido_id = p_pedido_id), '[]'::jsonb);
end;
$$;

grant execute on function
  servir_linea_escaneada(uuid, uuid, text, numeric, uuid, timestamptz),
  sugerir_caja(uuid), crear_bulto(uuid, text),
  anadir_a_bulto(uuid, text, numeric), cerrar_bulto(uuid, text),
  bultos_de_pedido(uuid)
to authenticated;


/* ─────────────────────────── Cajas de ejemplo ─────────────────────────── */

insert into tipos_caja (caja_id, nombre, largo_cm, ancho_cm, alto_cm, peso_vacio_g) values
  ('C1', 'Caja pequeña', 22, 16, 11, 120),
  ('C2', 'Caja mediana', 30, 22, 16, 210),
  ('C3', 'Caja grande',  40, 30, 25, 380)
on conflict (caja_id) do nothing;

-- ╔══ 20260920092100_22_panel.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  22 · PANEL
--
--  Cómo va el negocio, en una consulta. Todo se deriva del libro y de los
--  pedidos; no hay ninguna cifra almacenada que pueda quedarse vieja.
--
--  Los importes solo salen para quien puede verlos. Esta función es SECURITY
--  DEFINER —necesita leer tablas que un operario no lee—, así que la
--  comprobación de perfil la hace ella misma en lugar de delegarla en RLS.
--  Es la excepción, y por eso va escrita aquí de forma explícita.
-- ═══════════════════════════════════════════════════════════════════════════

insert into parametros (clave, valor, descripcion) values
  ('dias_cliente_dormido', '60',
   'Dias sin pedir tras los que un cliente cuenta como dormido en el panel')
on conflict (clave) do nothing;


create or replace function panel(p_dias integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_desde     date;
  v_anterior  date;
  v_dinero    boolean;
  v_ventas    jsonb;
  v_por_dia   jsonb;
  v_por_canal jsonb;
  v_top       jsonb;
  v_prod      jsonb;
  v_stock     jsonb;
  v_clientes  jsonb;
  v_avisos    jsonb;
begin
  if not app.tiene_nivel('OPERARIO') then
    raise exception 'Hay que identificarse.' using errcode = 'insufficient_privilege';
  end if;

  v_dinero := app.tiene_nivel('GESTOR');
  p_dias := greatest(1, least(coalesce(p_dias, 30), 730));
  v_desde := current_date - p_dias;
  v_anterior := v_desde - p_dias;

  -- El periodo se cierra HOY, arriba y abajo. Hay pedidos con fecha futura
  -- —un albarán de El Corte Inglés se firma con la fecha de entrega—, y si el
  -- total los contara mientras la serie por día se para en hoy, el gráfico y
  -- la cifra de encima dirían cosas distintas. Además, «lo vendido en 30
  -- días» no puede incluir lo que todavía no ha pasado.

  /* ── Ventas ──
     Se cuentan los pedidos ya servidos o entregados: un pedido confirmado
     todavía puede caerse, y contarlo como venta infla la cifra. */
  with servidos as (
    select p.pedido_id, p.fecha, p.canal, p.total, p.base, p.cliente_id
      from pedidos p
     where p.estado in ('SERVIDO', 'ENTREGADO')
       and p.fecha between v_desde and current_date
  ),
  lineas as (
    select pl.sku, pl.servidas, pl.importe, pl.precio_unit,
           coalesce(pr.coste_unitario, 0) as coste
      from pedido_lineas pl
      join servidos s on s.pedido_id = pl.pedido_id
      left join precios pr on pr.sku = pl.sku
  )
  select jsonb_build_object(
           'pedidos', (select count(*) from servidos),
           'unidades', (select coalesce(sum(servidas), 0) from lineas),
           'total', case when v_dinero
                      then (select coalesce(sum(total), 0) from servidos) end,
           'coste', case when v_dinero
                      then (select coalesce(sum(servidas * coste), 0) from lineas) end,
           'margen', case when v_dinero then (
                       select coalesce(sum(importe), 0) - coalesce(sum(servidas * coste), 0)
                         from lineas) end,
           -- Sin costes puestos el margen no significa nada, y más vale no
           -- enseñar un número que parece bueno porque falta la mitad.
           'costes_completos', (select count(*) = 0 from lineas where coste = 0),
           'anterior', case when v_dinero then (
                         select coalesce(sum(p.total), 0) from pedidos p
                          where p.estado in ('SERVIDO','ENTREGADO')
                            and p.fecha >= v_anterior and p.fecha < v_desde) end)
    into v_ventas;

  /* ── Por día, para ver la forma del periodo ── */
  select coalesce(jsonb_agg(jsonb_build_object(
           'fecha', d.dia::date, 'pedidos', coalesce(x.n, 0),
           'unidades', coalesce(x.uds, 0),
           'total', case when v_dinero then coalesce(x.total, 0) end) order by d.dia), '[]'::jsonb)
    into v_por_dia
    -- ::date, no `d.dia` a secas. generate_series sobre fechas devuelve
    -- TIMESTAMP, y sin el corte la serie sale como «2026-08-21T00:00:00+00:00»
    -- en vez de «2026-08-21». Quien la lee se encuentra una fecha con hora
    -- donde esperaba un día.
    from generate_series(v_desde, current_date, interval '1 day') as d(dia)
    left join (
      -- Agrupado por fecha y solo por fecha. Agrupar además por pedido daría
      -- una fila por pedido, y el día con tres pedidos saldría tres veces en
      -- la serie: tres barras para el mismo día.
      select p.fecha,
             count(*) as n,
             sum(p.total) as total,
             sum((select coalesce(sum(pl.servidas), 0) from pedido_lineas pl
                   where pl.pedido_id = p.pedido_id)) as uds
        from pedidos p
       where p.estado in ('SERVIDO','ENTREGADO') and p.fecha between v_desde and current_date
       group by p.fecha
    ) x on x.fecha = d.dia::date;

  /* ── Por canal ── */
  select coalesce(jsonb_agg(jsonb_build_object(
           'canal', canal, 'pedidos', n,
           'total', case when v_dinero then total end) order by n desc), '[]'::jsonb)
    into v_por_canal
    from (select p.canal, count(*) as n, sum(p.total) as total
            from pedidos p
           where p.estado in ('SERVIDO','ENTREGADO') and p.fecha between v_desde and current_date
           group by p.canal) z;

  /* ── Lo que más se vende ── */
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', sku, 'unidades', uds,
           'importe', case when v_dinero then importe end) order by uds desc), '[]'::jsonb)
    into v_top
    from (select pl.sku, sum(pl.servidas) as uds, sum(pl.importe) as importe
            from pedido_lineas pl
            join pedidos p on p.pedido_id = pl.pedido_id
           where p.estado in ('SERVIDO','ENTREGADO') and p.fecha between v_desde and current_date
           group by pl.sku
           having sum(pl.servidas) > 0
           order by 2 desc limit 8) z;

  /* ── Producción ── */
  select jsonb_build_object(
           'tuestes', count(*),
           'kg_verde', coalesce(sum((datos ->> 'kg_verde')::numeric), 0),
           'kg_tostado', coalesce(sum((datos ->> 'kg_tostado')::numeric), 0),
           'merma_media', round(avg((datos ->> 'merma_pct')::numeric), 1))
    into v_prod
    from operaciones
   where tipo = 'TUESTE' and ocurrido_en >= v_desde
     and ocurrido_en < current_date + 1
     and datos ? 'kg_verde';

  /* ── Stock ── */
  select jsonb_build_object(
           'unidades', coalesce(sum(s.cantidad) filter (where a.unidad = 'UD'), 0),
           'kg_verde', coalesce(sum(s.cantidad) filter (where a.unidad = 'KG'), 0),
           'valor', case when v_dinero then
             coalesce(sum(s.cantidad * coalesce(pr.coste_unitario, 0)), 0) end,
           'referencias', count(distinct s.sku))
    into v_stock
    from saldos s
    join articulos a on a.sku = s.sku
    left join precios pr on pr.sku = s.sku
   where s.cantidad > 0;

  /* ── Clientes ── */
  select jsonb_build_object(
           'nuevos', (select count(*) from clientes
                       where alta is not null and alta >= v_desde),
           'dormidos', (
             select count(*) from clientes c
              where c.activo
                and exists (select 1 from pedidos p where p.cliente_id = c.cliente_id)
                and not exists (
                  select 1 from pedidos p
                   where p.cliente_id = c.cliente_id
                     and p.fecha >= current_date - app.parametro_int('dias_cliente_dormido', 60))))
    into v_clientes;

  /* ── Lo que hay que mirar ── */
  select jsonb_build_object(
           'bajo_minimo', case when v_dinero then (
             select count(*) from (
               select pr.sku from precios pr
                where pr.stock_minimo is not null
                  and coalesce((select sum(s.cantidad) from saldos s where s.sku = pr.sku), 0)
                      <= pr.stock_minimo) z) end,
           'envejeciendo', (select count(*) from v_frescura where frescura <> 'FRESCO'),
           'incidencias', (select count(*) from incidencias where estado = 'ABIERTA'),
           'pedidos_pendientes', (select count(*) from pedidos
                                   where estado in ('CONFIRMADO','PREPARANDO')),
           'deposito_viejo', (select count(*) from v_deposito where envejecido))
    into v_avisos;

  return jsonb_build_object(
    'dias', p_dias, 'desde', v_desde, 'con_importes', v_dinero,
    'ventas', v_ventas, 'por_dia', v_por_dia, 'por_canal', v_por_canal,
    'top', v_top, 'produccion', v_prod, 'stock', v_stock,
    'clientes', v_clientes, 'avisos', v_avisos);
end;
$$;

grant execute on function panel(integer) to authenticated;

-- ╔══ 20260920092200_23_avisos.sql ══╗

-- ═══════════════════════════════════════════════════════════════════════════
--  23 · AVISO DIARIO POR CORREO
--
--  Un correo al día con lo de ayer y con lo que hay que mirar hoy. Es la
--  única pieza del sistema que sale a buscar a la persona en vez de esperar
--  a que abra la aplicación, y por eso hay que tratarla con cuidado.
--
--  DOS DECISIONES QUE VIENEN DE LA EXPERIENCIA CON ESTOS CORREOS
--
--  1) Se envía UNA VEZ AL DÍA, y eso se garantiza aquí, no en el servidor.
--     Vercel puede disparar un cron dos veces, un despliegue puede solaparse
--     con otro, y un reintento tras un fallo de red es normal. La fecha es
--     clave primaria: el segundo intento del mismo día no manda nada.
--
--  2) El correo lleva DETALLE, no solo cuentas. «3 referencias bajo mínimos»
--     obliga a abrir la aplicación para saber cuáles; con los nombres dentro,
--     se decide desde el propio correo mientras se desayuna. Un aviso que
--     obliga a ir a otro sitio para entenderlo acaba sin leerse.
-- ═══════════════════════════════════════════════════════════════════════════

create table avisos_enviados (
  fecha          date primary key,
  enviado_en     timestamptz not null default now(),
  destinatarios  text[] not null,
  resumen        jsonb not null
);

comment on table avisos_enviados is
  'Un correo por día, y la prueba de que se mandó. La clave primaria por '
  'fecha es lo que impide que un cron disparado dos veces envíe dos correos.';

alter table avisos_enviados enable row level security;
alter table avisos_enviados force row level security;
revoke all on avisos_enviados from anon, authenticated;

insert into parametros (clave, valor, descripcion) values
  ('avisos_solo_si_hay', 'no',
   'Con «si», el correo diario solo sale si hay algo que mirar. Con «no», '
   'sale siempre con el resumen de ventas'),
  ('avisos_hora', '7',
   'Hora aproximada a la que se espera el correo. Solo informativa: el '
   'horario de verdad está en vercel.json')
on conflict (clave) do nothing;


/**
 * Lo que va dentro del correo de un día. Con nombres, no solo con cuentas.
 *
 * Es SECURITY DEFINER y lleva importes, así que comprueba el perfil ella
 * misma: lo llama la tarea programada con perfil SISTEMA.
 */
create or replace function resumen_diario(p_fecha date default current_date - 1)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_ventas     jsonb;
  v_canales    jsonb;
  v_produccion jsonb;
  v_minimos    jsonb;
  v_frescura   jsonb;
  v_incid      jsonb;
  v_pendientes jsonb;
  v_deposito   jsonb;
  v_descuadres integer;
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'El resumen diario lleva importes.'
      using errcode = 'insufficient_privilege';
  end if;

  /* ── Lo que se vendió ayer ── */
  select jsonb_build_object(
           'pedidos', count(*),
           'total', coalesce(sum(p.total), 0),
           'unidades', coalesce((
             select sum(pl.servidas) from pedido_lineas pl
              join pedidos q on q.pedido_id = pl.pedido_id
              where q.estado in ('SERVIDO','ENTREGADO') and q.fecha = p_fecha), 0))
    into v_ventas
    from pedidos p
   where p.estado in ('SERVIDO','ENTREGADO') and p.fecha = p_fecha;

  select coalesce(jsonb_agg(jsonb_build_object(
           'canal', canal, 'pedidos', n, 'total', total) order by total desc), '[]'::jsonb)
    into v_canales
    from (select p.canal, count(*) as n, sum(p.total) as total
            from pedidos p
           where p.estado in ('SERVIDO','ENTREGADO') and p.fecha = p_fecha
           group by p.canal) z;

  select jsonb_build_object(
           'tuestes', count(*),
           'kg_verde', coalesce(sum((datos ->> 'kg_verde')::numeric), 0),
           'kg_tostado', coalesce(sum((datos ->> 'kg_tostado')::numeric), 0))
    into v_produccion
    from operaciones
   where tipo = 'TUESTE' and datos ? 'kg_verde'
     and ocurrido_en >= p_fecha and ocurrido_en < p_fecha + 1;

  /* ── Lo que hay que mirar, CON NOMBRES ── */
  select coalesce(jsonb_agg(jsonb_build_object(
           'sku', sku, 'quedan', quedan, 'minimo', minimo) order by quedan), '[]'::jsonb)
    into v_minimos
    from (
      select pr.sku,
             coalesce((select sum(s.cantidad) from saldos s where s.sku = pr.sku), 0) as quedan,
             pr.stock_minimo as minimo
        from precios pr
       where pr.stock_minimo is not null
         and coalesce((select sum(s.cantidad) from saldos s where s.sku = pr.sku), 0)
             <= pr.stock_minimo) z;

  select coalesce(jsonb_agg(jsonb_build_object(
           'lote', lote_id, 'sku', sku, 'ubicacion', ubicacion_id,
           'cantidad', cantidad, 'dias', dias_desde_tueste, 'estado', frescura)
           order by dias_desde_tueste desc), '[]'::jsonb)
    into v_frescura
    from v_frescura
   where frescura <> 'FRESCO';

  select coalesce(jsonb_agg(jsonb_build_object(
           'tipo', tipo, 'canal', canal, 'referencia', referencia,
           'desde', creado_en::date) order by creado_en), '[]'::jsonb)
    into v_incid
    from incidencias where estado = 'ABIERTA';

  -- Con el nombre del cliente, no con su identificador: el correo se lee en
  -- el móvil y «Bar Nuria» dice algo que un UUID no dice.
  select coalesce(jsonb_agg(jsonb_build_object(
           'pedido', p.numero, 'canal', p.canal,
           'cliente', coalesce(c.nombre, 'sin cliente'),
           'estado', p.estado, 'desde', p.fecha) order by p.fecha), '[]'::jsonb)
    into v_pendientes
    from pedidos p
    left join clientes c on c.cliente_id = p.cliente_id
   where p.estado in ('CONFIRMADO','PREPARANDO');

  select coalesce(jsonb_agg(jsonb_build_object(
           'ubicacion', ubicacion_id, 'sku', sku, 'saldo', saldo,
           'dias', dias_en_deposito) order by dias_en_deposito desc), '[]'::jsonb)
    into v_deposito
    from v_deposito where envejecido;

  -- Un descuadre entre el libro y la proyección no debería existir nunca. Si
  -- alguna vez existe, es lo primero que hay que leer del correo.
  select count(*) into v_descuadres from app.verificar_saldos();

  return jsonb_build_object(
    'fecha', p_fecha,
    'ventas', v_ventas,
    'canales', v_canales,
    'produccion', v_produccion,
    'minimos', v_minimos,
    'frescura', v_frescura,
    'incidencias', v_incid,
    'pendientes', v_pendientes,
    'deposito', v_deposito,
    'descuadres', v_descuadres,
    -- El ajuste viaja con el resumen en vez de consultarse aparte: PostgREST
    -- no publica el esquema `app`, y una segunda llamada para leer un
    -- parámetro es una ida y vuelta de más en algo que ya lo sabe.
    'solo_si_hay', lower(app.parametro('avisos_solo_si_hay', 'no')) = 'si',
    'hay_avisos', (
      jsonb_array_length(v_minimos) + jsonb_array_length(v_frescura)
      + jsonb_array_length(v_incid) + jsonb_array_length(v_deposito)
      + v_descuadres) > 0);
end;
$$;


/**
 * Reserva el envío del día. Devuelve false si ya se mandó.
 *
 * Se llama ANTES de mandar, no después: si se apuntara después, dos crones
 * a la vez pasarían los dos por la comprobación y saldrían dos correos. El
 * precio de hacerlo así es que un fallo del proveedor deja el día marcado
 * sin correo; por eso `soltar_aviso_diario` lo deshace.
 */
create or replace function reservar_aviso_diario(
  p_fecha date, p_destinatarios text[], p_resumen jsonb
) returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Solo el sistema envía los avisos.'
      using errcode = 'insufficient_privilege';
  end if;

  insert into avisos_enviados (fecha, destinatarios, resumen)
  values (p_fecha, p_destinatarios, p_resumen)
  on conflict (fecha) do nothing;

  return found;
end;
$$;

create or replace function soltar_aviso_diario(p_fecha date)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.tiene_nivel('GESTOR') then
    raise exception 'Solo el sistema envía los avisos.'
      using errcode = 'insufficient_privilege';
  end if;
  delete from avisos_enviados where fecha = p_fecha;
  return found;
end;
$$;

grant execute on function
  resumen_diario(date),
  reservar_aviso_diario(date, text[], jsonb),
  soltar_aviso_diario(date)
to authenticated;

-- ╔══ 20260920092300_24_vistas_invocador.sql ══╗

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
