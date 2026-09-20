import { NextResponse } from 'next/server';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { traerProductos } from '@/lib/woocommerce';
import { woocommerce as config } from '@/lib/integraciones';

export const dynamic = 'force-dynamic';

export async function GET() {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'GESTOR')) {
    return NextResponse.json({ error: 'Se necesita perfil de gestor.' }, { status: 403 });
  }
  if (!config.activo) {
    return NextResponse.json({ error: 'WooCommerce no está configurado todavía.' }, { status: 503 });
  }

  const db = comoUsuario(token);
  try {
    const [productos, mapeo, internos] = await Promise.all([
      traerProductos(),
      db.from('mapeo_articulos').select('codigo_externo, sku').eq('canal', 'woocommerce'),
      db.from('articulos').select('sku, clase').eq('activo', true),
    ]);

    return NextResponse.json({
      productos,
      mapeo: mapeo.data ?? [],
      internos: (internos.data ?? []).filter((a) => a.clase === 'PAQUETE'),
      ubicacion: config.ubicacion,
      colchon: config.colchon,
    });
  } catch (e) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : 'No se pudo consultar WooCommerce.' },
      { status: 502 },
    );
  }
}
