/**
 * Mantenimiento del catálogo.
 *
 * Un único punto de entrada con **lista blanca** de tablas y columnas. No es
 * un proxy genérico a la base: cada recurso declara qué campos admite y con
 * qué forma, y lo que no esté aquí no se puede tocar por esta vía.
 *
 * La autorización no se repite: la ponen las políticas RLS. Aquí solo se
 * declara el perfil mínimo para dar un error claro antes de llegar a la base,
 * en vez de un «permission denied» que no dice nada.
 */
import { z } from 'zod';
import type { Actor } from './tipos';

const codigoCorto = z.string().regex(/^[A-Z0-9]{2,10}$/,
  'De 2 a 10 caracteres, mayúsculas y números, sin espacios ni acentos');
const sku = z.string().regex(/^[A-Z0-9][A-Z0-9-]{1,39}$/, 'SKU con formato inválido');
const texto = (max = 200) => z.string().trim().max(max);
const opcional = (max = 200) => texto(max).nullish().transform((v) => v || null);

export const cafeSchema = z.object({
  cafe_id: codigoCorto,
  nombre: texto(120).min(2),
  origen: opcional(),
  variedad: opcional(),
  proceso: opcional(),
  altitud: opcional(60),
  perfil_tueste: opcional(60),
  notas_cata: opcional(300),
  activo: z.boolean().default(true),
});

export const formatoSchema = z.object({
  formato_id: z.string().regex(/^[A-Z0-9]{1,8}$/, 'Hasta 8 caracteres, mayúsculas y números'),
  nombre: texto(60).min(2),
  gramos: z.number().int().positive().max(25000),
  molienda: z.enum(['GRANO', 'MOLIDO']).default('GRANO'),
  activo: z.boolean().default(true),
});

/**
 * La coherencia entre clase, formato y unidad también la exige una
 * restricción de la base. Se comprueba aquí además para poder decir qué
 * falta, no para sustituirla.
 */
export const articuloSchema = z.object({
  sku,
  clase: z.enum(['VERDE', 'GRANEL', 'PAQUETE']),
  cafe_id: codigoCorto,
  formato_id: z.string().max(8).nullish().transform((v) => v || null),
  activo: z.boolean().default(true),
})
  .transform((a) => ({ ...a, unidad: a.clase === 'PAQUETE' ? 'UD' : 'KG' }))
  .refine((a) => a.clase !== 'PAQUETE' || !!a.formato_id,
    { message: 'Un paquete necesita formato', path: ['formato_id'] })
  .refine((a) => a.clase === 'PAQUETE' || !a.formato_id,
    { message: 'El café verde y el granel se llevan en kilos, sin formato', path: ['formato_id'] });

const importe = z.number().nonnegative().finite().nullish().transform((v) => v ?? null);

export const precioSchema = z.object({
  sku,
  precio_venta: importe,
  coste_unitario: importe,
  stock_minimo: importe,
  stock_objetivo: importe,
});

export const clienteSchema = z.object({
  cliente_id: z.string().uuid().optional(),
  nombre: texto(120).min(2),
  tipo: z.enum(['Particular', 'Hostelería', 'Tienda', 'Online', 'Distribuidor']),
  nif: opcional(20),
  email: z.string().trim().email().nullish().or(z.literal('')).transform((v) => v || null),
  telefono: opcional(20),
  direccion: opcional(),
  cp: opcional(10),
  poblacion: opcional(80),
  provincia: opcional(80),
  pais: texto(60).default('España'),
  descuento_pct: z.number().min(0).max(100).default(0),
  activo: z.boolean().default(true),
  notas: opcional(300),
});

export const parametroSchema = z.object({
  clave: z.string().regex(/^[a-z0-9_]{3,40}$/),
  valor: z.string().max(500),
});

export const ubicacionSchema = z.object({
  ubicacion_id: z.string().regex(/^[A-Z0-9_]{2,24}$/),
  nombre: texto(60).min(2),
  tipo: z.enum(['PROPIA', 'DEPOSITO', 'TRANSITO']),
  politica_lote: z.enum(['LOTE_ACTIVO', 'FIFO']),
  permite_venta: z.boolean(),
  activo: z.boolean().default(true),
  notas: opcional(300),
});

export interface Recurso {
  tabla: string;
  clave: string;
  esquema: z.ZodTypeAny;
  minimo: Actor;
  /** Columnas que se devuelven al listar. `*` para todas las permitidas. */
  orden: string;
  /** Si se puede borrar. El catálogo casi nunca: se desactiva, no se borra. */
  borrable: boolean;
}

export const RECURSOS: Record<string, Recurso> = {
  cafes:       { tabla: 'cafes', clave: 'cafe_id', esquema: cafeSchema,
                 minimo: 'GESTOR', orden: 'nombre', borrable: false },
  formatos:    { tabla: 'formatos', clave: 'formato_id', esquema: formatoSchema,
                 minimo: 'GESTOR', orden: 'gramos', borrable: false },
  articulos:   { tabla: 'articulos', clave: 'sku', esquema: articuloSchema,
                 minimo: 'GESTOR', orden: 'sku', borrable: false },
  precios:     { tabla: 'precios', clave: 'sku', esquema: precioSchema,
                 minimo: 'GESTOR', orden: 'sku', borrable: false },
  clientes:    { tabla: 'clientes', clave: 'cliente_id', esquema: clienteSchema,
                 minimo: 'GESTOR', orden: 'nombre', borrable: false },
  parametros:  { tabla: 'parametros', clave: 'clave', esquema: parametroSchema,
                 minimo: 'ADMIN', orden: 'clave', borrable: false },
  ubicaciones: { tabla: 'ubicaciones', clave: 'ubicacion_id', esquema: ubicacionSchema,
                 minimo: 'GESTOR', orden: 'nombre', borrable: false },
};

export function esRecurso(nombre: string): nombre is keyof typeof RECURSOS {
  return Object.hasOwn(RECURSOS, nombre);
}

/** Mensaje legible a partir de lo que devuelve Postgres. */
export function explicar(error: { message: string; code?: string }): string {
  if (error.code === '23505') {
    return 'Ya existe un registro con ese código. Los códigos no se pueden repetir.';
  }
  if (error.code === '23503') {
    return 'Hace referencia a algo que no existe, o hay movimientos que dependen de esto.';
  }
  if (error.code === '23514') {
    if (/ean13/.test(error.message)) {
      return 'El EAN-13 no es válido: el dígito de control no cuadra.';
    }
    return 'Los datos no cumplen alguna regla del catálogo. Revisa los campos.';
  }
  if (error.code === '42501') {
    return 'Tu perfil no permite hacer este cambio.';
  }
  return error.message;
}
