import { NextResponse } from 'next/server';
import { z } from 'zod';
import { acceder, firmar, guardarSesion } from '@/lib/sesion';

const cuerpo = z.object({
  usuarioId: z.string().uuid(),
  pin: z.string().regex(/^[0-9]{4,8}$/),
});

export async function POST(peticion: Request) {
  const leido = cuerpo.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) {
    return NextResponse.json({ error: 'Usuario o PIN con formato incorrecto.' }, { status: 400 });
  }

  const sesion = await acceder(leido.data.usuarioId, leido.data.pin);
  if (!sesion) {
    // Mismo mensaje y mismo código para usuario inexistente y PIN erróneo:
    // no se le dice a nadie qué mitad ha acertado.
    return NextResponse.json({ error: 'Usuario o PIN incorrectos.' }, { status: 401 });
  }

  await guardarSesion(await firmar(sesion));
  return NextResponse.json({ usuario: sesion });
}
