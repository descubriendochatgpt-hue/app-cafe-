import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, alcanza } from '@/lib/sesion';
import { telegram, registrarWebhook, estadoWebhook, quienEsElBot } from '@/lib/telegram';
import { baseUrl } from '@/lib/integraciones';

export const dynamic = 'force-dynamic';

/**
 * Puesta en marcha del bot sin salir de la aplicación.
 *
 * Telegram exige registrar la URL del webhook con una llamada a su API. Se
 * podría hacer con curl, pero entonces es un paso que se olvida, y el bot
 * queda mudo sin que nadie sepa por qué.
 */
export async function GET() {
  const sesion = await sesionActual();
  if (!sesion) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'ADMIN')) {
    return NextResponse.json({ error: 'Se necesita perfil de administrador.' }, { status: 403 });
  }
  if (!telegram.activo) {
    return NextResponse.json({
      configurado: false,
      urlEsperada: `${baseUrl()}/api/webhooks/telegram`,
    });
  }

  try {
    const [estado, bot] = await Promise.all([estadoWebhook(), quienEsElBot()]);
    const urlEsperada = `${baseUrl()}/api/webhooks/telegram`;

    return NextResponse.json({
      configurado: true,
      bot: bot.username ?? null,
      urlEsperada,
      urlRegistrada: estado.url || null,
      alDia: estado.url === urlEsperada,
      pendientes: estado.pending_update_count ?? 0,
      ultimoError: estado.last_error_message ?? null,
      secretoPuesto: !!telegram.secretoWebhook,
    });
  } catch (e) {
    return NextResponse.json(
      { configurado: true, error: e instanceof Error ? e.message : 'No se pudo consultar Telegram.' },
      { status: 502 },
    );
  }
}

const cuerpo = z.object({ accion: z.literal('registrar') });

export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  if (!sesion) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'ADMIN')) {
    return NextResponse.json({ error: 'Se necesita perfil de administrador.' }, { status: 403 });
  }

  const leido = cuerpo.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) return NextResponse.json({ error: 'Acción no reconocida.' }, { status: 400 });

  const url = `${baseUrl()}/api/webhooks/telegram`;
  if (url.includes('localhost')) {
    return NextResponse.json(
      { error: 'Telegram no puede llamar a localhost. Pon NEXT_PUBLIC_APP_URL con el dominio real.' },
      { status: 400 },
    );
  }

  try {
    await registrarWebhook(url);
    return NextResponse.json({ ok: true, url });
  } catch (e) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : 'No se pudo registrar el webhook.' },
      { status: 502 },
    );
  }
}
