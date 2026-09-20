import { NextResponse } from 'next/server';
import { sesionActual, tokenActual } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';

export const dynamic = 'force-dynamic';

/**
 * El panel. Una sola llamada: la función `panel()` arma todo el cuadro en la
 * base, donde están los datos, en lugar de traerse las tablas aquí para
 * sumarlas en JavaScript.
 *
 * Quién ve importes no lo decide esta capa. La función los deja fuera del
 * JSON cuando quien pregunta no llega a GESTOR, así que un operario no
 * recibe cifras de dinero ni aunque mire la respuesta de red.
 */
export async function GET(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const pedido = Number(new URL(peticion.url).searchParams.get('dias'));
  const dias = Number.isFinite(pedido) && pedido > 0 ? Math.floor(pedido) : 30;

  const { data, error } = await comoUsuario(token).rpc('panel', { p_dias: dias });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json(data);
}
