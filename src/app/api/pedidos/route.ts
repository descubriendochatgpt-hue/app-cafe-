import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { nuevaOperacionId } from '@/lib/uuid';

export const dynamic = 'force-dynamic';

/** Pedidos pendientes de salir, con sus líneas. */
export async function GET() {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const db = comoUsuario(token);
  const conImportes = alcanza(sesion.rol, 'GESTOR');

  // El operario lee de las vistas sin importes: no es que la pantalla los
  // oculte, es que su consulta no los trae.
  const [pedidos, lineas] = await Promise.all([
    db.from(conImportes ? 'pedidos' : 'pedidos_operativo').select('*')
      .in('estado', ['CONFIRMADO', 'PREPARANDO'])
      .order('fecha', { ascending: true }),
    db.from(conImportes ? 'pedido_lineas' : 'pedido_lineas_operativo').select('*'),
  ]);

  if (pedidos.error) return NextResponse.json({ error: pedidos.error.message }, { status: 500 });

  const porPedido = new Map<string, unknown[]>();
  for (const l of lineas.data ?? []) {
    const clave = (l as { pedido_id: string }).pedido_id;
    porPedido.set(clave, [...(porPedido.get(clave) ?? []), l]);
  }

  const { data: clientes } = await db.from('clientes').select('cliente_id, nombre');
  const nombres = new Map((clientes ?? []).map((c) => [c.cliente_id, c.nombre]));

  return NextResponse.json({
    conImportes,
    puedeCancelar: alcanza(sesion.rol, 'GESTOR'),
    pedidos: (pedidos.data ?? []).map((p) => ({
      ...p,
      cliente: nombres.get((p as { cliente_id: string | null }).cliente_id ?? '') ?? null,
      lineas: porPedido.get((p as { pedido_id: string }).pedido_id) ?? [],
    })),
  });
}

const accion = z.discriminatedUnion('accion', [
  z.object({ accion: z.literal('servir'), pedidoId: z.string().uuid() }),
  z.object({ accion: z.literal('cancelar'), pedidoId: z.string().uuid() }),
]);

export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const leido = accion.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) return NextResponse.json({ error: 'Acción no reconocida.' }, { status: 400 });

  if (leido.data.accion === 'cancelar' && !alcanza(sesion.rol, 'GESTOR')) {
    return NextResponse.json({ error: 'Se necesita perfil de gestor para cancelar.' }, { status: 403 });
  }

  const db = comoUsuario(token);
  const { data, error } = leido.data.accion === 'servir'
    ? await db.rpc('servir_reservas_pedido', {
        p_operacion_id: nuevaOperacionId(),
        p_pedido_id: leido.data.pedidoId,
        p_usuario_id: sesion.usuarioId,
        p_ocurrido_en: new Date().toISOString(),
      })
    : await db.rpc('liberar_reservas_pedido', {
        p_operacion_id: nuevaOperacionId(),
        p_pedido_id: leido.data.pedidoId,
        p_usuario_id: sesion.usuarioId,
        p_ocurrido_en: new Date().toISOString(),
      });

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  return NextResponse.json({ ok: true, resultado: data });
}
