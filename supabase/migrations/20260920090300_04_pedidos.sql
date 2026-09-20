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
