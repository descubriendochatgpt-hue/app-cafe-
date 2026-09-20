/**
 * Operaciones de inventario.
 *
 * Esta capa NO tiene lógica de inventario: valida la forma de lo que llega y
 * se la pasa a las funciones de dominio de Postgres, que son las que deciden.
 * La regla de no vender lo que no hay vive en una restricción de la base, no
 * aquí, y por eso sigue cumpliéndose aunque alguien escriba otro cliente.
 *
 * Lo único que sí es responsabilidad de esta capa: que el identificador de
 * operación lo ponga QUIEN ORIGINA el hecho (el móvil, antes de saber si hay
 * cobertura), nunca el servidor. Es lo que hace que reintentar sea inofensivo.
 */
import { z } from 'zod';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { ResultadoOperacion } from './tipos';

/* ── Formas de entrada ── */

const uuid = z.string().uuid('El identificador de operación tiene que ser un UUID');
const sku = z.string().regex(/^[A-Z0-9][A-Z0-9-]{1,39}$/, 'SKU con formato inválido');
const ubicacion = z.string().regex(/^[A-Z0-9_]{2,24}$/, 'Ubicación con formato inválido');
const cantidadPositiva = z.number().positive().finite();
const momento = z.string().datetime({ offset: true });

export const lineaVenta = z.object({
  sku,
  cantidad: cantidadPositiva,
  lote_id: z.string().min(4).optional(),
  precio_unit: z.number().nonnegative().optional(),
  dto_pct: z.number().min(0).max(100).optional(),
});

export const ventaSchema = z.object({
  operacionId: uuid,
  ubicacionId: ubicacion,
  lineas: z.array(lineaVenta).min(1, 'Una venta necesita al menos una línea'),
  canal: z.string().min(1).default('Mostrador'),
  clienteId: z.string().uuid().nullish(),
  origen: z.enum(['app', 'loyverse', 'woocommerce', 'eci', 'importacion', 'sistema']).default('app'),
  origenId: z.string().min(1).nullish(),
  documentoFiscal: z.string().min(1).nullish(),
  documentoFiscalSistema: z.enum(['loyverse', 'woocommerce', 'gestoria']).nullish(),
  formaPago: z.string().nullish(),
  ocurridoEn: momento,
  nota: z.string().nullish(),
});

export const tuesteSchema = z.object({
  operacionId: uuid,
  consumos: z.array(z.object({ lote_id: z.string().min(4), cantidad: cantidadPositiva })).min(1),
  producciones: z.array(z.object({
    sku,
    cantidad: cantidadPositiva,
    lote_id: z.string().min(4).nullish(),
  })).min(1),
  ubicacionId: ubicacion,
  ocurridoEn: momento,
  nota: z.string().nullish(),
});

export const trasladoSchema = z.object({
  operacionId: uuid,
  loteId: z.string().min(4),
  desde: ubicacion,
  hasta: ubicacion,
  cantidad: cantidadPositiva,
  ocurridoEn: momento,
  nota: z.string().nullish(),
});

export const movimientoSchema = z.object({
  operacionId: uuid,
  tipo: z.enum(['ENTRADA', 'SALIDA', 'MERMA', 'DEVOLUCION']),
  loteId: z.string().min(4),
  ubicacionId: ubicacion,
  cantidad: cantidadPositiva,
  ocurridoEn: momento,
  nota: z.string().nullish(),
});

export const recuentoSchema = z.object({
  operacionId: uuid,
  ubicacionId: ubicacion,
  recuento: z.array(z.object({
    lote_id: z.string().min(4),
    contado: z.number().nonnegative().finite(),
  })).min(1),
  ocurridoEn: momento,
  nota: z.string().nullish(),
});

export const recepcionVerdeSchema = z.object({
  operacionId: uuid,
  sku,
  cantidadKg: cantidadPositiva,
  ubicacionId: ubicacion,
  proveedor: z.string().nullish(),
  fechaRecepcion: z.string().date().nullish(),
  precioKg: z.number().nonnegative().nullish(),
  ocurridoEn: momento,
  nota: z.string().nullish(),
});

/* ── Errores ── */

export class ErrorInventario extends Error {
  constructor(
    mensaje: string,
    readonly codigo: string,
    readonly sinStock: boolean,
  ) {
    super(mensaje);
    this.name = 'ErrorInventario';
  }
}

function traducir(error: { message: string; code?: string; hint?: string | null }): never {
  const sinStock = error.hint === 'stock_insuficiente' || /No hay stock/i.test(error.message);
  throw new ErrorInventario(error.message, error.code ?? 'desconocido', sinStock);
}

async function llamar(
  db: SupabaseClient,
  funcion: string,
  argumentos: Record<string, unknown>,
): Promise<ResultadoOperacion> {
  const { data, error } = await db.rpc(funcion, argumentos);
  if (error) traducir(error);
  return data as ResultadoOperacion;
}

/* ── Operaciones ── */

export function registrarVenta(db: SupabaseClient, v: z.infer<typeof ventaSchema>) {
  return llamar(db, 'registrar_venta', {
    p_operacion_id: v.operacionId,
    p_ubicacion_id: v.ubicacionId,
    p_lineas: v.lineas,
    p_canal: v.canal,
    p_cliente_id: v.clienteId ?? null,
    p_origen: v.origen,
    p_origen_id: v.origenId ?? null,
    p_documento_fiscal: v.documentoFiscal ?? null,
    p_documento_fiscal_sistema: v.documentoFiscalSistema ?? null,
    p_forma_pago: v.formaPago ?? null,
    p_ocurrido_en: v.ocurridoEn,
    p_nota: v.nota ?? null,
  });
}

export function registrarTueste(db: SupabaseClient, t: z.infer<typeof tuesteSchema>) {
  return llamar(db, 'registrar_tueste', {
    p_operacion_id: t.operacionId,
    p_consumos: t.consumos,
    p_producciones: t.producciones,
    p_ubicacion_id: t.ubicacionId,
    p_ocurrido_en: t.ocurridoEn,
    p_nota: t.nota ?? null,
  });
}

export function registrarTraslado(db: SupabaseClient, t: z.infer<typeof trasladoSchema>) {
  return llamar(db, 'registrar_traslado', {
    p_operacion_id: t.operacionId,
    p_lote_id: t.loteId,
    p_origen_ubicacion: t.desde,
    p_destino_ubicacion: t.hasta,
    p_cantidad: t.cantidad,
    p_ocurrido_en: t.ocurridoEn,
    p_nota: t.nota ?? null,
  });
}

export function registrarMovimiento(db: SupabaseClient, m: z.infer<typeof movimientoSchema>) {
  return llamar(db, 'registrar_movimiento', {
    p_operacion_id: m.operacionId,
    p_tipo: m.tipo,
    p_lote_id: m.loteId,
    p_ubicacion_id: m.ubicacionId,
    p_cantidad: m.cantidad,
    p_ocurrido_en: m.ocurridoEn,
    p_nota: m.nota ?? null,
  });
}

export function registrarRecuento(db: SupabaseClient, r: z.infer<typeof recuentoSchema>) {
  return llamar(db, 'registrar_ajuste_inventario', {
    p_operacion_id: r.operacionId,
    p_ubicacion_id: r.ubicacionId,
    p_recuento: r.recuento,
    p_ocurrido_en: r.ocurridoEn,
    p_nota: r.nota ?? null,
  });
}

export function registrarRecepcionVerde(db: SupabaseClient, r: z.infer<typeof recepcionVerdeSchema>) {
  return llamar(db, 'registrar_recepcion_verde', {
    p_operacion_id: r.operacionId,
    p_sku: r.sku,
    p_cantidad_kg: r.cantidadKg,
    p_ubicacion_id: r.ubicacionId,
    p_proveedor: r.proveedor ?? null,
    p_fecha_recepcion: r.fechaRecepcion ?? null,
    p_precio_kg: r.precioKg ?? null,
    p_ocurrido_en: r.ocurridoEn,
    p_nota: r.nota ?? null,
  });
}

/* ── Despachador de la cola offline ──
   La PWA sube un lote de operaciones que grabó sin cobertura. Cada una lleva
   su UUID desde el móvil, así que subirlas dos veces es inofensivo. */

export const operacionEncolada = z.discriminatedUnion('tipo', [
  z.object({ tipo: z.literal('VENTA'), datos: ventaSchema }),
  z.object({ tipo: z.literal('TUESTE'), datos: tuesteSchema }),
  z.object({ tipo: z.literal('TRASLADO'), datos: trasladoSchema }),
  z.object({ tipo: z.literal('MOVIMIENTO'), datos: movimientoSchema }),
  z.object({ tipo: z.literal('RECUENTO'), datos: recuentoSchema }),
  z.object({ tipo: z.literal('RECEPCION_VERDE'), datos: recepcionVerdeSchema }),
]);

export type OperacionEncolada = z.infer<typeof operacionEncolada>;

export function despachar(db: SupabaseClient, op: OperacionEncolada): Promise<ResultadoOperacion> {
  switch (op.tipo) {
    case 'VENTA':           return registrarVenta(db, op.datos);
    case 'TUESTE':          return registrarTueste(db, op.datos);
    case 'TRASLADO':        return registrarTraslado(db, op.datos);
    case 'MOVIMIENTO':      return registrarMovimiento(db, op.datos);
    case 'RECUENTO':        return registrarRecuento(db, op.datos);
    case 'RECEPCION_VERDE': return registrarRecepcionVerde(db, op.datos);
  }
}
