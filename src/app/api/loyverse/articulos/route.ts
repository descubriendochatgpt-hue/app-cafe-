import { NextResponse } from 'next/server';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { traerArticulos } from '@/lib/loyverse';
import { loyverse as config } from '@/lib/integraciones';

export const dynamic = 'force-dynamic';

/** Artículos de Loyverse junto con el mapeo que ya exista, para la pantalla. */
export async function GET() {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'GESTOR')) {
    return NextResponse.json({ error: 'Se necesita perfil de gestor.' }, { status: 403 });
  }
  if (!config.activo) {
    return NextResponse.json({ error: 'Loyverse no está configurado todavía.' }, { status: 503 });
  }

  const db = comoUsuario(token);
  try {
    const [articulos, mapeo, internos] = await Promise.all([
      traerArticulos(),
      db.from('mapeo_articulos').select('codigo_externo, sku').eq('canal', 'loyverse'),
      db.from('articulos').select('sku, clase, cafe_id, formato_id').eq('activo', true),
    ]);

    return NextResponse.json({
      articulos,
      mapeo: mapeo.data ?? [],
      internos: (internos.data ?? []).filter((a) => a.clase === 'PAQUETE'),
    });
  } catch (e) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : 'No se pudo consultar Loyverse.' },
      { status: 502 },
    );
  }
}
