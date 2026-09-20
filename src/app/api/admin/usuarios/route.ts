import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { explicar } from '@/lib/admin';

export const dynamic = 'force-dynamic';

/**
 * Gestión de usuarios. El PIN no pasa nunca por una tabla: entra por
 * funciones que lo cifran, así que no puede acabar en claro en un registro
 * ni en una copia de seguridad.
 */
export async function GET() {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'ADMIN')) {
    return NextResponse.json({ error: 'Se necesita perfil de administrador.' }, { status: 403 });
  }

  const { data, error } = await comoUsuario(token).rpc('usuarios_administrables');
  if (error) return NextResponse.json({ error: explicar(error) }, { status: 500 });
  return NextResponse.json({ usuarios: data ?? [], yo: sesion.usuarioId });
}

const pin = z.string().regex(/^[0-9]{4,8}$/, 'El PIN tiene que ser de 4 a 8 cifras');

const accion = z.discriminatedUnion('accion', [
  z.object({
    accion: z.literal('crear'),
    nombre: z.string().trim().min(2).max(80),
    pin,
    rol: z.enum(['OPERARIO', 'GESTOR', 'ADMIN']),
  }),
  z.object({ accion: z.literal('rol'), usuarioId: z.string().uuid(),
             rol: z.enum(['OPERARIO', 'GESTOR', 'ADMIN']) }),
  z.object({ accion: z.literal('activar'), usuarioId: z.string().uuid(), activo: z.boolean() }),
  z.object({ accion: z.literal('pin'), usuarioId: z.string().uuid(), pin }),
  z.object({ accion: z.literal('desbloquear'), usuarioId: z.string().uuid() }),
]);

export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const leido = accion.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) {
    return NextResponse.json(
      { error: leido.error.issues[0]?.message ?? 'Datos no válidos.' }, { status: 400 });
  }
  const a = leido.data;

  // Cambiarse el PIN a uno mismo no necesita ser administrador; lo demás sí.
  const propio = a.accion === 'pin' && a.usuarioId === sesion.usuarioId;
  if (!propio && !alcanza(sesion.rol, 'ADMIN')) {
    return NextResponse.json({ error: 'Se necesita perfil de administrador.' }, { status: 403 });
  }

  const db = comoUsuario(token);
  const { error } =
      a.accion === 'crear'      ? await db.rpc('crear_usuario',
                                    { p_nombre: a.nombre, p_pin: a.pin, p_rol: a.rol })
    : a.accion === 'rol'        ? await db.rpc('cambiar_rol_usuario',
                                    { p_usuario_id: a.usuarioId, p_rol: a.rol })
    : a.accion === 'activar'    ? await db.rpc('activar_usuario',
                                    { p_usuario_id: a.usuarioId, p_activo: a.activo })
    : a.accion === 'pin'        ? await db.rpc('cambiar_pin',
                                    { p_usuario_id: a.usuarioId, p_pin_nuevo: a.pin })
    :                             await db.rpc('desbloquear_acceso',
                                    { p_usuario_id: a.usuarioId });

  if (error) return NextResponse.json({ error: explicar(error) }, { status: 400 });
  return NextResponse.json({ ok: true });
}
