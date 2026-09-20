/**
 * Subida de operaciones, una o muchas.
 *
 * Es el punto por el que entra todo lo que hace una persona, tanto si lo hizo
 * con cobertura como si lo grabó en un mercado y se subió tres horas después.
 *
 * Contrato con la PWA:
 *   · cada operación llega con el UUID que le puso el MÓVIL
 *   · se procesan en orden y cada una responde por separado
 *   · reenviar el lote entero es inofensivo: lo ya contabilizado vuelve
 *     marcado como `idempotente` y no se aplica dos veces
 *
 * Por eso la app puede reintentar a ciegas sin llevar la cuenta de qué llegó.
 */
import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { despachar, operacionEncolada, ErrorInventario } from '@/lib/inventario';

const cuerpo = z.object({
  operaciones: z.array(operacionEncolada).min(1).max(200),
});

export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) {
    return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  }

  const leido = cuerpo.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) {
    return NextResponse.json(
      { error: 'Operaciones mal formadas.', detalle: leido.error.issues },
      { status: 400 },
    );
  }

  const db = comoUsuario(token);
  const resultados = [];

  for (const op of leido.data.operaciones) {
    try {
      resultados.push({
        operacionId: op.datos.operacionId,
        estado: 'ok' as const,
        resultado: await despachar(db, op),
      });
    } catch (e) {
      // Una operación que falla no tumba el resto del lote: la cola de la PWA
      // necesita saber exactamente cuál se quedó fuera para conservarla.
      const error = e instanceof ErrorInventario
        ? { mensaje: e.message, sinStock: e.sinStock, codigo: e.codigo }
        : { mensaje: e instanceof Error ? e.message : 'Error desconocido', sinStock: false, codigo: 'desconocido' };
      resultados.push({ operacionId: op.datos.operacionId, estado: 'error' as const, error });
    }
  }

  const fallidas = resultados.filter((r) => r.estado === 'error').length;
  return NextResponse.json(
    { resultados, aplicadas: resultados.length - fallidas, fallidas },
    // 207: el lote se procesó, pero no todo salió bien. La PWA conserva en su
    // cola solo las que fallaron.
    { status: fallidas > 0 ? 207 : 200 },
  );
}
