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
as $$
  select crypt(p_pin, gen_salt('bf', 10));
$$;

create or replace function app.pin_correcto(p_usuario_id uuid, p_pin text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
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
