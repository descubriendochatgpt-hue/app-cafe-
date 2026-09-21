'use client';

/**
 * Almacén local del navegador (IndexedDB).
 *
 * Guarda dos cosas y por razones distintas:
 *
 *   `cola`     — las operaciones que todavía no han llegado al servidor.
 *                Es lo que hace que se pueda vender en un mercado sin
 *                cobertura. Cada una lleva su UUID desde que nace, así que
 *                subirlas dos veces no duplica nada.
 *
 *   `catalogo` — copia de lo que hace falta para trabajar: qué es cada lote
 *                y cuánto hay en cada sitio. Se refresca cuando hay red.
 *
 * Se usa IndexedDB y no localStorage porque localStorage es síncrono (bloquea
 * la interfaz mientras escribe) y tiene un límite de unos 5 MB.
 */
import { openDB, type DBSchema, type IDBPDatabase } from 'idb';

export interface EnCola {
  operacionId: string;
  tipo: string;
  datos: Record<string, unknown>;
  creadoEn: string;
  intentos: number;
  ultimoError?: string;
  /** Un fallo que no se arregla reintentando necesita a una persona. */
  bloqueada?: boolean;
}

export interface Catalogo {
  lotes: LoteDetalle[];
  saldos: SaldoDetalle[];
  ubicaciones: Ubicacion[];
  articulos: Articulo[];
  formatos: Formato[];
  cafes: Cafe[];
  precios: Precio[];
  parametros: Record<string, string>;
  descargado: string;
}

export interface Cafe {
  cafe_id: string; nombre: string; origen: string | null;
}

export interface LoteDetalle {
  lote_id: string; sku: string; clase: string; unidad: string;
  ean13: string | null; cafe_id: string; cafe: string; origen: string | null;
  formato: string | null; gramos: number | null; molienda: string | null;
  fecha_tostado: string | null; fecha_consumo_preferente: string | null;
  dias_desde_tueste: number | null; frescura: string; stock_total: number;
}

export interface SaldoDetalle {
  lote_id: string; sku: string; ubicacion_id: string; ubicacion: string;
  tipo_ubicacion: string; cantidad: number; reservado: number;
  disponible: number; es_lote_activo: boolean;
}

export interface Ubicacion {
  ubicacion_id: string; nombre: string; tipo: string;
  politica_lote: string; permite_venta: boolean;
}

export interface Articulo {
  sku: string; clase: string; cafe_id: string;
  formato_id: string | null; unidad: string; ean13: string | null;
}

export interface Formato {
  formato_id: string; nombre: string; gramos: number; molienda: string;
}

export interface Precio {
  sku: string; precio_venta: number | null; coste_unitario: number | null;
  stock_minimo: number | null; stock_objetivo: number | null;
}

interface Esquema extends DBSchema {
  cola: { key: string; value: EnCola; indexes: { 'por-fecha': string } };
  cache: { key: string; value: { clave: string; valor: unknown } };
}

let promesa: Promise<IDBPDatabase<Esquema>> | null = null;

function db(): Promise<IDBPDatabase<Esquema>> {
  promesa ??= openDB<Esquema>('cafe', 1, {
    upgrade(base) {
      const cola = base.createObjectStore('cola', { keyPath: 'operacionId' });
      cola.createIndex('por-fecha', 'creadoEn');
      base.createObjectStore('cache', { keyPath: 'clave' });
    },
  });
  return promesa;
}

/* ── Cola ── */

export async function encolar(op: Omit<EnCola, 'intentos' | 'creadoEn'>): Promise<void> {
  await (await db()).put('cola', { ...op, creadoEn: new Date().toISOString(), intentos: 0 });
}

export async function pendientes(): Promise<EnCola[]> {
  const todas = await (await db()).getAllFromIndex('cola', 'por-fecha');
  return todas.filter((o) => !o.bloqueada);
}

export async function bloqueadas(): Promise<EnCola[]> {
  return (await (await db()).getAll('cola')).filter((o) => o.bloqueada);
}

export async function cuantasPendientes(): Promise<number> {
  return (await pendientes()).length;
}

export async function quitarDeCola(operacionId: string): Promise<void> {
  await (await db()).delete('cola', operacionId);
}

export async function marcarFallo(
  operacionId: string,
  error: string,
  bloqueada: boolean,
): Promise<void> {
  const base = await db();
  const op = await base.get('cola', operacionId);
  if (!op) return;
  await base.put('cola', { ...op, intentos: op.intentos + 1, ultimoError: error, bloqueada });
}

/* ── Catálogo ── */

export async function guardarCatalogo(c: Catalogo): Promise<void> {
  await (await db()).put('cache', { clave: 'catalogo', valor: c });
}

export async function leerCatalogo(): Promise<Catalogo | null> {
  const fila = await (await db()).get('cache', 'catalogo');
  return (fila?.valor as Catalogo | undefined) ?? null;
}
