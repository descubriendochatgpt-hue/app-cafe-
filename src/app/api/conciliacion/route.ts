import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';

export const dynamic = 'force-dynamic';

/** Todo lo que necesita una decisión humana, en un sitio. */
export async function GET() {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const db = comoUsuario(token);
  const [incidencias, eventos, descuadres] = await Promise.all([
    db.from('incidencias').select('*').eq('estado', 'ABIERTA')
      .order('creado_en', { ascending: false }).limit(100),
    db.from('eventos_entrada').select('*').eq('estado', 'FALLIDO')
      .order('recibido_en', { ascending: false }).limit(50),
    db.rpc('verificar_saldos_publico'),
  ]);

  return NextResponse.json({
    incidencias: incidencias.data ?? [],
    eventos: eventos.data ?? [],
    descuadres: descuadres.data ?? [],
    puedeResolver: alcanza(sesion.rol, 'GESTOR'),
  });
}

const accion = z.discriminatedUnion('accion', [
  z.object({ accion: z.literal('reintentar'), eventoId: z.string().uuid() }),
  z.object({
    accion: z.literal('resolver'),
    incidenciaId: z.string().uuid(),
    resolucion: z.string().min(1).max(500),
  }),
]);

export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'GESTOR')) {
    return NextResponse.json({ error: 'Se necesita perfil de gestor.' }, { status: 403 });
  }

  const leido = accion.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) return NextResponse.json({ error: 'Acción no reconocida.' }, { status: 400 });

  const db = comoUsuario(token);
  const { error } = leido.data.accion === 'reintentar'
    ? await db.rpc('reintentar_evento', { p_evento_id: leido.data.eventoId })
    : await db.rpc('resolver_incidencia', {
        p_incidencia_id: leido.data.incidenciaId,
        p_resolucion: leido.data.resolucion,
      });

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true });
}
