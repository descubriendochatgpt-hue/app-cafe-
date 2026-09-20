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
