import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { baseUrl } from '@/lib/integraciones';

export const dynamic = 'force-dynamic';

/** Clientes de hostelería con el estado de su enlace. */
export async function GET() {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'GESTOR')) {
    return NextResponse.json({ error: 'Se necesita perfil de gestor.' }, { status: 403 });
  }

  const db = comoUsuario(token);
  const { data, error } = await db
    .from('clientes')
    .select('cliente_id, nombre, tipo, telefono, descuento_pct, token_pedido, token_creado_en')
    .eq('activo', true)
    .order('nombre');

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json({
    base: baseUrl(),
    clientes: (data ?? []).map((c) => ({
      ...c,
      // El token completo no hace falta en el listado; el enlace sí.
      enlace: c.token_pedido ? `${baseUrl()}/pedido/${c.token_pedido}` : null,
    })),
  });
}

const cuerpo = z.object({
  clienteId: z.string().uuid(),
  accion: z.enum(['generar', 'revocar']),
});

export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'GESTOR')) {
    return NextResponse.json({ error: 'Se necesita perfil de gestor.' }, { status: 403 });
  }

  const leido = cuerpo.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) return NextResponse.json({ error: 'Petición no válida.' }, { status: 400 });

  const db = comoUsuario(token);
  if (leido.data.accion === 'revocar') {
    const { error } = await db.rpc('revocar_enlace_pedido', { p_cliente_id: leido.data.clienteId });
    if (error) return NextResponse.json({ error: error.message }, { status: 500 });
    return NextResponse.json({ ok: true, enlace: null });
  }

  const { data, error } = await db.rpc('generar_enlace_pedido', {
    p_cliente_id: leido.data.clienteId,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json({ ok: true, enlace: `${baseUrl()}/pedido/${data}` });
}
