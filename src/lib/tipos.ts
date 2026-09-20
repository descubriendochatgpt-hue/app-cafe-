/**
 * Tipos del dominio. Se corresponden uno a uno con los tipos enumerados de
 * Postgres: si allí se añade un valor, aquí falla la compilación.
 */

export const ROLES = ['OPERARIO', 'GESTOR', 'ADMIN'] as const;
export type Rol = (typeof ROLES)[number];

/** El actor de los conectores automáticos. No es un rol de persona. */
export type Actor = Rol | 'SISTEMA';

export const TIPOS_OPERACION = [
  'RECEPCION_VERDE', 'TUESTE', 'TRASLADO', 'VENTA', 'DEVOLUCION',
  'ENTRADA', 'SALIDA', 'MERMA', 'AJUSTE', 'RESERVA', 'LIBERACION',
] as const;
export type TipoOperacion = (typeof TIPOS_OPERACION)[number];

export const ORIGENES = [
  'app', 'loyverse', 'woocommerce', 'eci', 'importacion', 'sistema',
] as const;
export type Origen = (typeof ORIGENES)[number];

export interface Sesion {
  usuarioId: string;
  nombre: string;
  rol: Rol;
}

export interface ResultadoOperacion {
  idempotente: boolean;
  operacion_id: string;
  [clave: string]: unknown;
}

/** Una operación tal y como la encola la PWA cuando no hay cobertura. */
export interface OperacionEncolada {
  operacionId: string;
  tipo: TipoOperacion;
  ocurridoEn: string;
  carga: Record<string, unknown>;
}
