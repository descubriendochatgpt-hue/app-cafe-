/**
 * Tipos del dominio. Se corresponden uno a uno con los tipos enumerados de
 * Postgres: si allí se añade un valor, aquí falla la compilación.
 */

export const ROLES = ['OPERARIO', 'GESTOR', 'ADMIN'] as const;
export type Rol = (typeof ROLES)[number];

/** El actor de los conectores automáticos. No es un rol de persona. */
export type Actor = Rol | 'SISTEMA';

/**
 * Jerarquía de permisos. Tiene que coincidir con app.nivel() en Postgres.
 *
 * Vive aquí, entre los tipos, y no junto a la firma del token: es un hecho
 * del dominio, y la navegación —que corre en el navegador— necesita
 * consultarlo sin arrastrarse la librería de criptografía al paquete.
 */
export const NIVEL: Record<Actor, number> = {
  OPERARIO: 1, GESTOR: 2, ADMIN: 3, SISTEMA: 4,
};

export function alcanza(rol: Actor, minimo: Actor): boolean {
  return NIVEL[rol] >= NIVEL[minimo];
}

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
