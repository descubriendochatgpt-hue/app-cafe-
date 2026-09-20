import { NextResponse } from 'next/server';
import { sesionActual, tokenActual } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';

export const dynamic = 'force-dynamic';

/**
 * Informes que se derivan del libro. Ninguno guarda nada: son consultas.
 *
 * `v_deposito` es el criterio de aceptación del régimen de depósito escrito
 * como consulta: servido − vendido − devuelto = saldo, con un `descuadre`
 * que tiene que ser cero siempre.
 */
export async function GET(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const lote = new URL(peticion.url).searchParams.get('lote');
  const db = comoUsuario(token);

  if (lote) {
    const { data, error } = await db
      .from('v_trazabilidad').select('*').eq('lote', lote).order('nivel');
    if (error) return NextResponse.json({ error: error.message }, { status: 500 });
    return NextResponse.json({ trazabilidad: data ?? [] });
  }

  const [deposito, frescura, lotes] = await Promise.all([
    db.from('v_deposito').select('*').order('dias_en_deposito', { ascending: false }),
    db.from('v_frescura').select('*').neq('frescura', 'FRESCO')
      .order('dias_desde_tueste', { ascending: false }),
    db.from('v_lote_detalle').select('lote_id, cafe, formato, fecha_tostado, stock_total')
      .eq('clase', 'PAQUETE').order('fecha_tostado', { ascending: false }).limit(60),
  ]);

  const fallo = [deposito, frescura, lotes].find((r) => r.error);
  if (fallo?.error) return NextResponse.json({ error: fallo.error.message }, { status: 500 });

  return NextResponse.json({
    deposito: deposito.data ?? [],
    frescura: frescura.data ?? [],
    lotes: lotes.data ?? [],
  });
}
