import { NextResponse } from 'next/server';
import { sesionActual, tokenActual } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';

/**
 * Todo lo que la PWA necesita llevarse al móvil para trabajar sin cobertura:
 * qué es cada lote, qué hay en cada sitio y dónde se puede vender.
 *
 * Se descarga entero porque el catálogo es pequeño (20-30 referencias) y así
 * un escaneo en un mercado sin red sigue diciendo qué café es y cuánto queda.
 */
export async function GET() {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) {
    return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  }

  const db = comoUsuario(token);
  const [lotes, saldos, ubicaciones, articulos, formatos, cafes, parametros] = await Promise.all([
    db.from('v_lote_detalle').select('*'),
    db.from('v_saldo_detalle').select('*'),
    db.from('ubicaciones').select('*').eq('activo', true).order('nombre'),
    db.from('articulos').select('sku, clase, cafe_id, formato_id, unidad, ean13').eq('activo', true),
    db.from('formatos').select('*').eq('activo', true),
    // Los cafés van con su nombre: sin esto, las pantallas solo podían
    // enseñar el código —«KENYAA · 250 g»— y quien tuesta conoce el café por
    // su nombre, no por la clave con la que lo dimos de alta.
    db.from('cafes').select('cafe_id, nombre, origen').eq('activo', true).order('nombre'),
    db.from('parametros').select('clave, valor'),
  ]);

  const fallo = [lotes, saldos, ubicaciones, articulos, formatos, cafes, parametros].find((r) => r.error);
  if (fallo?.error) {
    return NextResponse.json({ error: fallo.error.message }, { status: 500 });
  }

  // El operario no recibe precios: las políticas RLS ya no le devuelven
  // esas filas, así que aquí no hay nada que filtrar.
  const precios = sesion.rol === 'OPERARIO'
    ? { data: [] }
    : await db.from('precios').select('*');

  return NextResponse.json({
    lotes: lotes.data ?? [],
    saldos: saldos.data ?? [],
    ubicaciones: ubicaciones.data ?? [],
    articulos: articulos.data ?? [],
    formatos: formatos.data ?? [],
    cafes: cafes.data ?? [],
    parametros: Object.fromEntries((parametros.data ?? []).map((p) => [p.clave, p.valor])),
    precios: precios.data ?? [],
    usuario: sesion,
    descargado: new Date().toISOString(),
  });
}
