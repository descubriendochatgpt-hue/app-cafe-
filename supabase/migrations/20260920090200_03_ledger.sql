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
