import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';

export const dynamic = 'force-dynamic';

/** Un pedido con sus líneas, sus bultos y qué caja convendría. */
export async function GET(
  _p: Request, { params }: { params: Promise<{ pedidoId: string }> },
) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const { pedidoId } = await params;
  if (!z.string().uuid().safeParse(pedidoId).success) {
    return NextResponse.json({ error: 'Pedido no válido.' }, { status: 400 });
  }

  const db = comoUsuario(token);
  const conImportes = alcanza(sesion.rol, 'GESTOR');

  const [pedido, lineas, bultos, sugerencia, cajas] = await Promise.all([
    db.from(conImportes ? 'pedidos' : 'pedidos_operativo').select('*')
      .eq('pedido_id', pedidoId).maybeSingle(),
    db.from(conImportes ? 'pedido_lineas' : 'pedido_lineas_operativo').select('*')
      .eq('pedido_id', pedidoId),
    db.rpc('bultos_de_pedido', { p_pedido_id: pedidoId }),
    db.rpc('sugerir_caja', { p_pedido_id: pedidoId }),
    db.from('tipos_caja').select('*').eq('activo', true).order('nombre'),
  ]);

  if (pedido.error) return NextResponse.json({ error: pedido.error.message }, { status: 500 });
  if (!pedido.data) return NextResponse.json({ error: 'Ese pedido no existe.' }, { status: 404 });

  return NextResponse.json({
    pedido: pedido.data,
    lineas: lineas.data ?? [],
    bultos: bultos.data ?? [],
    sugerencia: sugerencia.data ?? null,
    cajas: cajas.data ?? [],
    conImportes,
  });
}

const accion = z.discriminatedUnion('accion', [
  z.object({ accion: z.literal('crear-bulto'), cajaId: z.string().max(12).nullish() }),
  z.object({
    accion: z.literal('anadir'),
    bultoId: z.string().uuid(),
    loteId: z.string().min(4),
    cantidad: z.number().positive().max(999).default(1),
  }),
  z.object({
    accion: z.literal('cerrar-bulto'),
    bultoId: z.string().uuid(),
    seguimiento: z.string().max(80).nullish(),
  }),
]);

/**
 * Empaquetar. A diferencia de preparar, esto NO pasa por la cola offline:
 * no toca el inventario, y un bulto a medio montar sin subir sería más lío
 * que utilidad. Si no hay cobertura, se prepara ahora y se empaqueta después.
 */
export async function POST(
  peticion: Request, { params }: { params: Promise<{ pedidoId: string }> },
) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const { pedidoId } = await params;
  const leido = accion.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) return NextResponse.json({ error: 'Acción no reconocida.' }, { status: 400 });

  const db = comoUsuario(token);
  const a = leido.data;

  const { data, error } =
      a.accion === 'crear-bulto'
        ? await db.rpc('crear_bulto', { p_pedido_id: pedidoId, p_caja_id: a.cajaId ?? null })
    : a.accion === 'anadir'
        ? await db.rpc('anadir_a_bulto', {
            p_bulto_id: a.bultoId, p_lote_id: a.loteId, p_cantidad: a.cantidad })
    :     await db.rpc('cerrar_bulto', {
            p_bulto_id: a.bultoId, p_seguimiento: a.seguimiento ?? null });

  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json({ ok: true, resultado: data });
}
