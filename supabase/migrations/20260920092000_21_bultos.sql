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
