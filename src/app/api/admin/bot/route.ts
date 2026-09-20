import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { explicar } from '@/lib/admin';

export const dynamic = 'force-dynamic';

export async function GET() {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const db = comoUsuario(token);

  // Un administrador ve todos los accesos; cualquiera ve el suyo, que es lo
  // que necesita para saber si ya se dio de alta.
  const { data, error } = alcanza(sesion.rol, 'ADMIN')
    ? await db.rpc('bot_autorizados_lista')
    : await db.from('bot_autorizados').select('canal, id_externo, usuario_id, alias, creado_en, ultimo_uso');

  if (error) return NextResponse.json({ error: explicar(error) }, { status: 500 });
  return NextResponse.json({
    autorizados: data ?? [],
    esAdmin: alcanza(sesion.rol, 'ADMIN'),
    yo: sesion.usuarioId,
  });
}

const accion = z.discriminatedUnion('accion', [
  z.object({ accion: z.literal('codigo') }),
  z.object({
    accion: z.literal('revocar'),
    canal: z.enum(['instagram', 'prueba']),
    idExterno: z.string().min(1).max(120),
  }),
]);

export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const leido = accion.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) return NextResponse.json({ error: 'Acción no reconocida.' }, { status: 400 });

  const db = comoUsuario(token);

  if (leido.data.accion === 'codigo') {
    const { data, error } = await db.rpc('generar_codigo_bot');
    if (error) return NextResponse.json({ error: explicar(error) }, { status: 400 });
    return NextResponse.json(data);
  }

  const { error } = await db.rpc('revocar_bot', {
    p_canal: leido.data.canal, p_id_externo: leido.data.idExterno,
  });
  if (error) return NextResponse.json({ error: explicar(error) }, { status: 400 });
  return NextResponse.json({ ok: true });
}
