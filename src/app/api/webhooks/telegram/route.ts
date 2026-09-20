/**
 * Mensajes de Telegram.
 *
 * Telegram reintenta si no recibe un 200, así que se responde 200 salvo
 * cuando el secreto no cuadra. Un fallo al contestar una pregunta no debe
 * hacer que Telegram reenvíe el mismo mensaje una y otra vez.
 */
import { NextResponse } from 'next/server';
import {
  telegram, envioAutentico, extraerMensaje, responderPorTelegram,
} from '@/lib/telegram';
import { atender } from '@/lib/bot';

export const dynamic = 'force-dynamic';
export const maxDuration = 30;

export function GET() {
  return NextResponse.json({
    ok: true,
    canal: 'telegram',
    configurado: telegram.activo,
    secreto: telegram.secretoWebhook ? 'exigido' : 'no exigido',
  });
}

export async function POST(peticion: Request) {
  const autentico = envioAutentico(peticion.headers, telegram.secretoWebhook);
  if (!autentico.valido) {
    return NextResponse.json({ error: autentico.motivo }, { status: 401 });
  }
  if (!telegram.activo) {
    return NextResponse.json({ error: 'Telegram no está configurado.' }, { status: 503 });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(await peticion.text());
  } catch {
    return NextResponse.json({ ok: true, nota: 'Cuerpo ilegible, descartado.' });
  }

  const m = extraerMensaje(payload);
  if (!m) {
    // Grupos, otros bots, ediciones: nada que responder. Los grupos se
    // descartan a propósito, no por simplificar: en un grupo verían la
    // respuesta personas que no están autorizadas.
    return NextResponse.json({ ok: true, atendido: false });
  }

  try {
    const alias = m.alias ? `@${m.alias}` : m.nombre;
    const r = await atender('telegram', m.remitente, m.texto, alias ?? undefined);
    if (r.texto) await responderPorTelegram(m.chat, r.texto);
    return NextResponse.json({ ok: true, resultado: r.resultado });
  } catch (e) {
    const motivo = e instanceof Error ? e.message : 'desconocido';
    try {
      await responderPorTelegram(m.chat, 'Ahora mismo no puedo responder. Inténtalo en un rato.');
    } catch { /* sin nada más que hacer */ }
    return NextResponse.json({ ok: true, resultado: 'error', motivo });
  }
}
