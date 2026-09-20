import { NextResponse } from 'next/server';
import { sesionActual, tokenActual } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';

/**
 * Stock consolidado. No filtra importes a mano: las políticas RLS ya hacen
 * que un operario no reciba las filas de precios, así que aunque alguien
 * añadiera la columna aquí, no habría nada que ocultar.
 */
export async function GET(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) {
    return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  }

  const ubicacion = new URL(peticion.url).searchParams.get('ubicacion');
  let consulta = comoUsuario(token).from('v_stock').select('*').order('cafe').order('formato');
  if (ubicacion) consulta = consulta.eq('ubicacion_id', ubicacion);

  const { data, error } = await consulta;
  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
  return NextResponse.json({ stock: data });
}
