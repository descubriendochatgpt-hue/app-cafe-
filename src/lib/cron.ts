import { entorno } from './entorno';

/**
 * Las tareas programadas están expuestas en internet como cualquier otra
 * ruta. Sin esto, cualquiera podría dispararlas y provocar consultas
 * constantes a Loyverse, que acabaría limitándonos.
 *
 * Vercel envía la cabecera sola una vez configurado CRON_SECRET.
 */
export function autorizada(peticion: Request): boolean {
  const esperado = entorno().CRON_SECRET;
  if (!esperado) return process.env.NODE_ENV !== 'production';   // en local, sin fricción

  const cabecera = peticion.headers.get('authorization') ?? '';
  return cabecera === `Bearer ${esperado}`;
}
