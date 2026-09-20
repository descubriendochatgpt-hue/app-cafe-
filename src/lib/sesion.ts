/**
 * Sesión dentro de una petición.
 *
 * El PIN se comprueba en la base (contra bcrypt) y, si es correcto, se firma
 * un JWT. Ese JWT es el que hace que las políticas RLS sepan quién pregunta.
 * El control de acceso no se implementa aquí: se DELEGA en la base. Esta capa
 * solo acredita quién eres.
 */
import { cookies } from 'next/headers';
import { comoSistema } from './supabase';
import { entorno } from './entorno';
import { firmarToken, leerToken, esRol } from './jwt';
import type { Sesion } from './tipos';

export { alcanza } from './jwt';

const COOKIE = 'sesion';

export function firmar(sesion: Sesion): Promise<string> {
  const env = entorno();
  return firmarToken(sesion, env.SUPABASE_JWT_SECRET, env.SESION_HORAS);
}

/** Comprueba el PIN contra la base. No distingue usuario inexistente de PIN malo. */
export async function acceder(usuarioId: string, pin: string): Promise<Sesion | null> {
  const { data, error } = await comoSistema().rpc('acceder', {
    p_usuario_id: usuarioId,
    p_pin: pin,
  });
  if (error) throw new Error(`No se pudo comprobar el PIN: ${error.message}`);

  const fila = Array.isArray(data) ? data[0] : null;
  if (!fila || !esRol(fila.rol)) return null;

  return { usuarioId: fila.usuario_id, nombre: fila.nombre, rol: fila.rol };
}

export async function sesionActual(): Promise<Sesion | null> {
  const token = (await cookies()).get(COOKIE)?.value;
  return token ? leerToken(token, entorno().SUPABASE_JWT_SECRET) : null;
}

export async function tokenActual(): Promise<string | null> {
  return (await cookies()).get(COOKIE)?.value ?? null;
}

export async function guardarSesion(token: string): Promise<void> {
  (await cookies()).set(COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === 'production',
    sameSite: 'lax',
    path: '/',
    maxAge: entorno().SESION_HORAS * 3600,
  });
}

export async function cerrarSesion(): Promise<void> {
  (await cookies()).delete(COOKIE);
}
