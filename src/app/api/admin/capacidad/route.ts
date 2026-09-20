import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { explicar } from '@/lib/admin';

export const dynamic = 'force-dynamic';

/**
 * Cuántos paquetes de cada formato caben en cada caja.
 *
 * Va en su propia ruta porque su clave son dos columnas, y el editor
 * genérico del catálogo asume una sola. Se mide una vez, metiéndolos de
 * verdad: calcularlo por volumen da números que después no salen.
 */
export async function GET() {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const db = comoUsuario(token);
  const [capacidad, formatos] = await Promise.all([
    db.from('capacidad_caja').select('*'),
    db.from('formatos').select('formato_id, nombre, gramos').eq('activo', true).order('gramos'),
  ]);

  if (capacidad.error) return NextResponse.json({ error: capacidad.error.message }, { status: 500 });
  return NextResponse.json({ capacidad: capacidad.data ?? [], formatos: formatos.data ?? [] });
}

const cuerpo = z.object({
  cajaId: z.string().regex(/^[A-Z0-9_]{1,12}$/),
  formatoId: z.string().regex(/^[A-Z0-9]{1,8}$/),
  // Cero o vacío quita la fila: esa caja no admite ese formato.
  unidadesMax: z.number().int().min(0).max(9999).nullable(),
});

export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'GESTOR')) {
    return NextResponse.json({ error: 'Se necesita perfil de gestor.' }, { status: 403 });
  }

  const leido = cuerpo.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) return NextResponse.json({ error: 'Datos no válidos.' }, { status: 400 });
  const { cajaId, formatoId, unidadesMax } = leido.data;

  const db = comoUsuario(token);
  const { error } = !unidadesMax
    ? await db.from('capacidad_caja').delete().eq('caja_id', cajaId).eq('formato_id', formatoId)
    : await db.from('capacidad_caja')
        .upsert({ caja_id: cajaId, formato_id: formatoId, unidades_max: unidadesMax },
                { onConflict: 'caja_id,formato_id' });

  if (error) return NextResponse.json({ error: explicar(error) }, { status: 400 });
  return NextResponse.json({ ok: true });
}
