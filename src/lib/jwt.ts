/**
 * Firma y verificación del token de sesión. Sin dependencias de Next: es
 * lógica pura, y así se puede probar sin levantar un servidor.
 *
 * El token se firma con el secreto JWT de Supabase precisamente para que lo
 * entienda PostgREST: `sub` acaba en app.usuario_actual() y `rol` en
 * app.rol_actual(), que son las que evalúan las políticas RLS.
 */
import { SignJWT, jwtVerify } from 'jose';
import { ROLES, type Rol, type Sesion, type Actor } from './tipos';

export function esRol(valor: unknown): valor is Rol {
  return typeof valor === 'string' && (ROLES as readonly string[]).includes(valor);
}

function clave(secreto: string): Uint8Array {
  return new TextEncoder().encode(secreto);
}

export async function firmarToken(
  sesion: Sesion,
  secreto: string,
  horas: number,
): Promise<string> {
  return new SignJWT({ rol: sesion.rol, nombre: sesion.nombre, role: 'authenticated' })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setSubject(sesion.usuarioId)
    .setIssuedAt()
    .setExpirationTime(`${horas}h`)
    .sign(clave(secreto));
}

export async function leerToken(token: string, secreto: string): Promise<Sesion | null> {
  try {
    const { payload } = await jwtVerify(token, clave(secreto), { algorithms: ['HS256'] });
    if (!payload.sub || !esRol(payload.rol)) return null;
    return {
      usuarioId: payload.sub,
      nombre: typeof payload.nombre === 'string' ? payload.nombre : '',
      rol: payload.rol,
    };
  } catch {
    // Firma inválida, caducado, algoritmo cambiado o manipulado: da lo mismo.
    return null;
  }
}

/** Jerarquía de permisos. Tiene que coincidir con app.nivel() en Postgres. */
const NIVEL: Record<Actor, number> = {
  OPERARIO: 1, GESTOR: 2, ADMIN: 3, SISTEMA: 4,
};

export function alcanza(rol: Actor, minimo: Actor): boolean {
  return NIVEL[rol] >= NIVEL[minimo];
}
