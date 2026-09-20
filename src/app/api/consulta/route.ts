import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { responder } from '@/lib/consultas';

export const dynamic = 'force-dynamic';

/**
 * Las mismas preguntas del bot, desde dentro de la aplicación.
 *
 * Sirve para dos cosas: probar las respuestas sin depender de la aprobación
 * de Meta, y tener las consultas a mano en la propia app para quien prefiera
 * escribir a navegar.
 */
const cuerpo = z.object({ pregunta: z.string().trim().min(1).max(300) });

export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });

  const leido = cuerpo.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) return NextResponse.json({ error: 'Pregunta no válida.' }, { status: 400 });

  try {
    // Con el token de quien pregunta: las mismas reglas que en cualquier
    // otra pantalla, ni una más ni una menos.
    const texto = await responder(comoUsuario(token), leido.data.pregunta, sesion.rol);
    return NextResponse.json({ respuesta: texto });
  } catch (e) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : 'No se pudo responder.' }, { status: 500 });
  }
}
