#!/usr/bin/env node
/**
 * ════════════════════════════════════════════════════════════════════════
 *  IMPORTACIÓN DESDE LAS HOJAS DE CÁLCULO
 *
 *  Lee los CSV exportados del sistema antiguo (Apps Script sobre Google
 *  Sheets) y ESCRIBE UN FICHERO SQL. No toca la base: genera algo que se
 *  puede leer antes de aplicarlo, que es lo que se quiere en una migración
 *  donde el negocio sigue funcionando mientras tanto.
 *
 *  QUÉ IMPORTA Y QUÉ NO
 *
 *    Maestros (cafés, formatos, referencias, precios, clientes) → se copian.
 *
 *    Lotes → se conservan con su identificador, su fecha de tueste y el saco
 *      de verde del que salieron. Es lo que mantiene la trazabilidad y los
 *      avisos de frescura desde el primer día.
 *
 *    Existencias → NO se reproduce el histórico de movimientos, sino que se
 *      calcula el saldo de cada lote y se registra como UNA operación de
 *      apertura fechada y etiquetada. Reproducir miles de apuntes antiguos
 *      daría el mismo número con mucho más riesgo, y el detalle previo sigue
 *      estando en la hoja, que se conserva como archivo.
 *
 *    Pedidos y facturas antiguos → se quedan en la hoja. El sistema nuevo no
 *      emite documentos fiscales, así que arrastrar facturas emitidas por
 *      otro sistema solo crearía registros duplicados.
 *
 *  TODO EN UNA ÚNICA UBICACIÓN
 *
 *    El sistema antiguo no tenía ubicaciones: todo era un almacén implícito.
 *    Por eso la apertura carga en ALMACEN, y el reparto real (tienda,
 *    furgoneta, depósito) se hace el día del corte con un recuento por
 *    ubicación. Inventarse ese reparto aquí sería inventarse datos.
 *
 *  USO
 *    node scripts/importar.mjs --entrada ./export --salida ./importacion.sql
 *    node scripts/importar.mjs --entrada ./export --comparar > comparacion.sql
 * ════════════════════════════════════════════════════════════════════════
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import Papa from 'papaparse';

/* ── Utilidades ── */

const NAMESPACE = 'cafe-importacion-2026';

/** UUID determinista: reimportar dos veces produce las mismas operaciones,
 *  así que la idempotencia de la base las descarta en lugar de duplicarlas. */
function uuidDe(clave) {
  const h = createHash('sha1').update(`${NAMESPACE}:${clave}`).digest();
  h[6] = (h[6] & 0x0f) | 0x50;   // versión 5
  h[8] = (h[8] & 0x3f) | 0x80;   // variante RFC 4122
  const x = h.subarray(0, 16).toString('hex');
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20, 32)}`;
}

const cita = (v) =>
  v === null || v === undefined || v === '' ? 'null' : `'${String(v).replace(/'/g, "''")}'`;
const num = (v) => {
  const n = Number(String(v ?? '').replace(',', '.'));
  return Number.isFinite(n) ? n : 0;
};
const sí = (v) => String(v ?? '').trim().toUpperCase() !== 'NO';

function leerCsv(dir, nombre) {
  const ruta = join(dir, `${nombre}.csv`);
  if (!existsSync(ruta)) return null;
  const { data, errors } = Papa.parse(readFileSync(ruta, 'utf8').replace(/^﻿/, ''), {
    header: true, skipEmptyLines: true, transformHeader: (h) => h.trim(),
  });
  if (errors.length) {
    console.error(`  ! ${nombre}.csv: ${errors.length} línea(s) con problemas, la primera en la ${errors[0].row}`);
  }
  return data.filter((f) => Object.values(f).some((v) => String(v ?? '').trim() !== ''));
}

/** Identificador de lote: se conservan los guiones, que son lo que lo hace
 *  legible en una etiqueta. Solo se quitan acentos y espacios. */
const limpiarLote = (t) =>
  String(t ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .toUpperCase().replace(/[^A-Z0-9-]/g, '').slice(0, 64);

/** Dígito de control de un EAN-13. Misma comprobación que hace la base: más
 *  vale descartar aquí un código mal copiado que abortar toda la importación
 *  por una sola fila. */
function eanValido(codigo) {
  if (!/^[0-9]{13}$/.test(codigo)) return false;
  let suma = 0;
  for (let i = 0; i < 12; i++) suma += Number(codigo[i]) * (i % 2 ? 3 : 1);
  return (10 - (suma % 10)) % 10 === Number(codigo[12]);
}

/** Código corto válido para la base: mayúsculas, sin acentos ni espacios. */
const limpiar = (t, max = 10) =>
  String(t ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, max);

/* ── Argumentos ── */

const args = process.argv.slice(2);
const opcion = (nombre, defecto) => {
  const i = args.indexOf(`--${nombre}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : defecto;
};
const entrada = opcion('entrada', './export');
const salida = opcion('salida', './importacion.sql');
const soloComparar = args.includes('--comparar');
const fechaApertura = opcion('fecha', new Date().toISOString().slice(0, 10));

if (!existsSync(entrada)) {
  console.error(`No encuentro la carpeta ${entrada}.`);
  console.error('Exporta cada pestaña de la hoja como CSV con su mismo nombre:');
  console.error('  Productos.csv  Formatos.csv  Referencias.csv  CafeVerde.csv');
  console.error('  Lotes.csv  Movimientos.csv  Clientes.csv');
  process.exit(1);
}

/* ── Lectura ── */

console.error(`Leyendo de ${entrada}`);
const productos   = leerCsv(entrada, 'Productos')   ?? [];
const formatos    = leerCsv(entrada, 'Formatos')    ?? [];
const referencias = leerCsv(entrada, 'Referencias') ?? [];
const cafeVerde   = leerCsv(entrada, 'CafeVerde')   ?? [];
const lotes       = leerCsv(entrada, 'Lotes')       ?? [];
const movimientos = leerCsv(entrada, 'Movimientos') ?? [];
const clientes    = leerCsv(entrada, 'Clientes')    ?? [];

for (const [n, f] of Object.entries({ productos, formatos, referencias, cafeVerde, lotes, movimientos, clientes })) {
  console.error(`  ${String(f.length).padStart(6)} ${n}`);
}

/* ── Saldos por lote, sumando el libro antiguo ── */

const saldo = new Map();
for (const m of movimientos) {
  const lote = String(m.lote_id ?? '').trim();
  if (!lote) continue;
  saldo.set(lote, (saldo.get(lote) ?? 0) + num(m.unidades));
}

/* ── Modo comparación: para el periodo de doble registro ── */

if (soloComparar) {
  // La hoja antigua no llevaba el café verde en el libro de movimientos: su
  // saldo era una resta (recibido − consumido por los tuestes). Para que la
  // comparación sea de igual a igual, aquí se calcula del mismo modo.
  const consumido = new Map();
  for (const l of lotes) {
    const v = String(l.lote_verde_id ?? '').trim();
    if (v) consumido.set(v, (consumido.get(v) ?? 0) + num(l.kg_verde));
  }
  const verdes = cafeVerde
    .map((v) => [limpiarLote(v.lote_verde_id), num(v.kg_recibidos) - (consumido.get(v.lote_verde_id) ?? 0)])
    .filter(([, kg]) => kg > 0);

  const filas = [...saldo.entries(), ...verdes]
    .filter(([, v]) => v !== 0)
    .map(([lote, uds]) => `    (${cita(lote)}, ${uds})`);

  process.stdout.write(`-- Comparación entre la hoja de cálculo y el sistema nuevo.
-- Se ejecuta durante el periodo de doble registro: mientras la hoja siga
-- siendo la verdad, esta consulta tiene que devolver CERO filas antes de
-- dar el corte por bueno.
--
-- Generada el ${new Date().toISOString()} a partir de ${movimientos.length} movimientos.

with hoja (lote_id, unidades) as (values
${filas.join(',\n')}
),
nuevo as (
  select lote_id, sum(cantidad) as unidades from saldos group by lote_id
)
select coalesce(h.lote_id, n.lote_id)      as lote,
       coalesce(h.unidades, 0)             as segun_la_hoja,
       coalesce(n.unidades, 0)             as segun_la_app,
       coalesce(n.unidades, 0) - coalesce(h.unidades, 0) as diferencia
  from hoja h
  full outer join nuevo n on n.lote_id = h.lote_id
 where coalesce(h.unidades, 0) <> coalesce(n.unidades, 0)
 order by abs(coalesce(n.unidades, 0) - coalesce(h.unidades, 0)) desc;
`);
  process.exit(0);
}

/* ── Generación del SQL ── */

const L = [];
const avisos = [];
L.push(`-- ════════════════════════════════════════════════════════════════════`);
L.push(`--  Importación desde las hojas de cálculo`);
L.push(`--  Generada el ${new Date().toISOString()}`);
L.push(`--  Origen: ${entrada}`);
L.push(`--`);
L.push(`--  Se puede aplicar más de una vez sin duplicar nada: los maestros`);
L.push(`--  usan ON CONFLICT y las operaciones llevan identificadores`);
L.push(`--  deterministas, así que la base las reconoce como ya contabilizadas.`);
L.push(`-- ════════════════════════════════════════════════════════════════════`);
L.push(``);
L.push(`begin;`);
L.push(`set local app.rol = 'ADMIN';`);
L.push(``);

/* Cafés */
L.push(`-- ── Cafés ──`);
for (const p of productos) {
  const id = limpiar(p.sku);
  if (!id) { avisos.push(`Café sin código, descartado: ${JSON.stringify(p).slice(0, 80)}`); continue; }
  L.push(`insert into cafes (cafe_id, nombre, origen, variedad, proceso, altitud, perfil_tueste, notas_cata, activo) values`);
  L.push(`  (${cita(id)}, ${cita(p.nombre || id)}, ${cita(p.origen)}, ${cita(p.variedad)}, ${cita(p.proceso)}, ${cita(p.altitud)}, ${cita(p.perfil_tueste)}, ${cita(p.notas_cata)}, ${sí(p.activo)})`);
  L.push(`  on conflict (cafe_id) do update set nombre = excluded.nombre;`);
}

/* Formatos */
L.push(``, `-- ── Formatos ──`);
for (const f of formatos) {
  const id = limpiar(f.formato_id, 8);
  if (!id || !num(f.gramos)) { avisos.push(`Formato sin código o sin gramos: ${f.formato_id}`); continue; }
  // El sistema antiguo no distinguía grano de molido: entra todo como grano
  // y se separa después, si hace falta, dando de alta el formato molido.
  L.push(`insert into formatos (formato_id, nombre, gramos, molienda, activo) values`);
  L.push(`  (${cita(id)}, ${cita(f.nombre || id)}, ${num(f.gramos)}, 'GRANO', ${sí(f.activo)})`);
  L.push(`  on conflict (formato_id) do update set nombre = excluded.nombre, gramos = excluded.gramos;`);
}

/* Artículos de café verde: uno por café con sacos */
L.push(``, `-- ── Artículos de café verde ──`);
const verdesPorCafe = new Map();
for (const v of cafeVerde) {
  // El saco antiguo no dice de qué café es; se deduce del lote tostado que
  // lo consumió, y si no hay ninguno se asocia al primer café del catálogo.
  const usado = lotes.find((l) => String(l.lote_verde_id ?? '') === String(v.lote_verde_id ?? ''));
  const cafe = limpiar(usado?.sku) || limpiar(productos[0]?.sku);
  if (!cafe) { avisos.push(`Saco de verde sin café asociado: ${v.lote_verde_id}`); continue; }
  verdesPorCafe.set(v.lote_verde_id, cafe);
}
for (const cafe of new Set(verdesPorCafe.values())) {
  L.push(`insert into articulos (sku, clase, cafe_id, formato_id, unidad) values`);
  L.push(`  (${cita(`VRD-${cafe}`)}, 'VERDE', ${cita(cafe)}, null, 'KG') on conflict (sku) do nothing;`);
}

/* Artículos empaquetados y precios */
L.push(``, `-- ── Referencias empaquetadas y sus precios ──`);
const skuDe = new Map();
for (const r of referencias) {
  const cafe = limpiar(r.sku);
  const formato = limpiar(r.formato_id, 8);
  if (!cafe || !formato) { avisos.push(`Referencia incompleta: ${r.ref_id}`); continue; }
  const sku = `${cafe}-${formato}`;
  skuDe.set(String(r.ref_id ?? `${r.sku}-${r.formato_id}`), sku);

  const eanBruto = String(r.ean13 ?? '').trim();
  const ean = eanValido(eanBruto) ? eanBruto : null;
  if (eanBruto && !ean) {
    avisos.push(`EAN inválido en ${r.ref_id}: «${eanBruto}». Se importa sin código; hay que reasignarlo en Ajustes.`);
  }
  L.push(`insert into articulos (sku, clase, cafe_id, formato_id, unidad, ean13, activo) values`);
  L.push(`  (${cita(sku)}, 'PAQUETE', ${cita(cafe)}, ${cita(formato)}, 'UD', ${ean ? cita(ean) : 'null'}, ${sí(r.activo)})`);
  L.push(`  on conflict (sku) do update set ean13 = excluded.ean13, activo = excluded.activo;`);
  L.push(`insert into precios (sku, precio_venta, coste_unitario, stock_minimo, stock_objetivo) values`);
  L.push(`  (${cita(sku)}, ${num(r.precio_venta)}, ${num(r.coste_unitario)}, ${num(r.stock_minimo)}, ${num(r.stock_optimo)})`);
  L.push(`  on conflict (sku) do update set precio_venta = excluded.precio_venta, coste_unitario = excluded.coste_unitario, stock_minimo = excluded.stock_minimo;`);
}

/* Clientes */
L.push(``, `-- ── Clientes ──`);
for (const c of clientes) {
  if (!String(c.nombre ?? '').trim()) continue;
  L.push(`insert into clientes (cliente_id, nombre, tipo, nif, email, telefono, direccion, cp, poblacion, provincia, descuento_pct, activo) values`);
  L.push(`  (${cita(uuidDe(`cliente:${c.cliente_id}`))}, ${cita(c.nombre)}, ${cita(c.tipo || 'Particular')}, ${cita(String(c.nif || '').trim() || null)}, ${cita(String(c.email || '').trim() || null)}, ${cita(c.telefono)}, ${cita(c.direccion)}, ${cita(c.cp)}, ${cita(c.poblacion)}, ${cita(c.provincia)}, ${num(c.descuento_pct)}, ${sí(c.activo)})`);
  L.push(`  on conflict (cliente_id) do update set nombre = excluded.nombre;`);
}

/* Lotes de café verde */
L.push(``, `-- ── Sacos de café verde ──`);
L.push(`-- Se registran con los kilos que quedaban, no con los recibidos: lo ya`);
L.push(`-- tostado está en los lotes de tostado y contarlo dos veces lo duplicaría.`);
const consumidoVerde = new Map();
for (const l of lotes) {
  const v = String(l.lote_verde_id ?? '').trim();
  if (v) consumidoVerde.set(v, (consumidoVerde.get(v) ?? 0) + num(l.kg_verde));
}
for (const v of cafeVerde) {
  const cafe = verdesPorCafe.get(v.lote_verde_id);
  if (!cafe) continue;
  const quedan = num(v.kg_recibidos) - (consumidoVerde.get(v.lote_verde_id) ?? 0);
  if (quedan <= 0) continue;
  L.push(`select registrar_recepcion_verde(${cita(uuidDe(`verde:${v.lote_verde_id}`))}, ${cita(`VRD-${cafe}`)}, ${quedan.toFixed(3)}, 'ALMACEN', ${cita(v.proveedor)}, ${cita(String(v.fecha_recepcion || '').slice(0, 10) || fechaApertura)}, ${num(v.precio_kg) || 'null'}, null, ${cita(`${fechaApertura}T08:00:00+02`)}::timestamptz, ${cita(limpiarLote(v.lote_verde_id) || uuidDe(`vid:${v.lote_verde_id}`).slice(0, 12))}, 'Saldo migrado de la hoja');`);
}

/* Lotes tostados con su saldo de apertura */
L.push(``, `-- ── Lotes tostados y saldo de apertura ──`);
L.push(`-- Un apunte por lote, fechado y etiquetado. El detalle anterior se`);
L.push(`-- conserva en la hoja, que pasa a ser archivo de solo lectura.`);
let conSaldo = 0, sinReferencia = 0;
for (const l of lotes) {
  const loteId = String(l.lote_id ?? '').trim();
  const uds = saldo.get(loteId) ?? 0;
  if (!loteId || uds <= 0) continue;

  const cafe = limpiar(l.sku);
  const formato = limpiar(l.formato_id, 8);
  const sku = `${cafe}-${formato}`;
  if (!cafe || !formato) { sinReferencia++; avisos.push(`Lote sin café o formato reconocible: ${loteId}`); continue; }

  const tostado = String(l.fecha_tostado || '').slice(0, 10) || fechaApertura;
  L.push(`insert into articulos (sku, clase, cafe_id, formato_id, unidad) values (${cita(sku)}, 'PAQUETE', ${cita(cafe)}, ${cita(formato)}, 'UD') on conflict (sku) do nothing;`);
  L.push(`insert into lotes (lote_id, sku, fecha_tostado, fecha_consumo_preferente, notas) values`);
  L.push(`  (${cita(loteId)}, ${cita(sku)}, ${cita(tostado)}::date, ${cita(String(l.fecha_consumo_preferente || '').slice(0, 10) || null)}::date, 'Importado de la hoja')`);
  L.push(`  on conflict (lote_id) do nothing;`);
  L.push(`select registrar_movimiento(${cita(uuidDe(`apertura:${loteId}`))}, 'ENTRADA', ${cita(loteId)}, 'ALMACEN', ${uds}, null, ${cita(`${fechaApertura}T08:00:00+02`)}::timestamptz, 'Saldo de apertura migrado de la hoja');`);
  conSaldo++;
}

L.push(``);
L.push(`commit;`);
L.push(``);
L.push(`-- Comprobación inmediata: esto tiene que dar cero filas.`);
L.push(`select * from app.verificar_saldos();`);

writeFileSync(salida, L.join('\n') + '\n');

console.error(``);
console.error(`Escrito ${salida}`);
console.error(`  ${conSaldo} lotes con existencias`);
console.error(`  ${saldo.size - conSaldo} lotes agotados (no se importan)`);
if (sinReferencia) console.error(`  ${sinReferencia} lotes descartados por falta de referencia`);
if (avisos.length) {
  console.error(``);
  console.error(`AVISOS (${avisos.length}):`);
  for (const a of avisos.slice(0, 20)) console.error(`  · ${a}`);
  if (avisos.length > 20) console.error(`  … y ${avisos.length - 20} más`);
}
console.error(``);
console.error(`Revisa el fichero ANTES de aplicarlo:`);
console.error(`  psql -f ${salida}`);
