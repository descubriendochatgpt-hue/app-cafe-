import { NextResponse } from 'next/server';
import { z } from 'zod';
import { acceder, firmar, guardarSesion, esperaDeAcceso } from '@/lib/sesion';

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
    // Usuario inexistente, PIN erróneo y cuenta bloqueada devuelven lo mismo:
    // no se le dice a nadie qué mitad ha acertado.
    //
    // La única concesión es el tiempo de espera, y solo cuando ya hay
    // bloqueo: a quien se ha equivocado cinco veces hay que decirle cuánto
    // falta, y a quien está probando combinaciones esa cifra no le sirve de
    // nada, porque ya sabe que está bloqueado.
    const espera = await esperaDeAcceso(leido.data.usuarioId);
    return NextResponse.json(
      espera > 0
        ? { error: `Demasiados intentos. Vuelve a probar en ${Math.ceil(espera / 60)} min.`,
            esperaSegundos: espera }
        : { error: 'Usuario o PIN incorrectos.' },
      { status: espera > 0 ? 429 : 401 },
    );
  }

  await guardarSesion(await firmar(sesion));
  return NextResponse.json({ usuario: sesion });
}
