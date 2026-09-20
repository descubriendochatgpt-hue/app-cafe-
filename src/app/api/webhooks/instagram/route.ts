/**
 * Mensajes directos de Instagram.
 *
 * Meta reintenta si no recibe un 200, así que se responde 200 salvo cuando
 * la firma no cuadra. Un fallo al contestar una pregunta no debe provocar
 * que Meta reenvíe el mensaje una y otra vez.
 */
import { NextResponse } from 'next/server';
import { instagram, firmaValida, extraerMensajes, responderPorInstagram } from '@/lib/instagram';
import { atender } from '@/lib/bot';

export const dynamic = 'force-dynamic';
export const maxDuration = 30;

/** Meta comprueba la URL antes de guardarla, y repite la comprobación al renovar. */
export async function GET(peticion: Request) {
  const p = new URL(peticion.url).searchParams;

  if (p.get('hub.mode') === 'subscribe'
      && p.get('hub.verify_token') === instagram.tokenVerificacion
      && instagram.tokenVerificacion) {
    // Meta espera el desafío en crudo, sin JSON alrededor.
    return new Response(p.get('hub.challenge') ?? '', {
      status: 200, headers: { 'Content-Type': 'text/plain' },
    });
  }

  if (p.has('hub.mode')) {
    return new Response('Token de verificación incorrecto.', { status: 403 });
  }

  return NextResponse.json({
    ok: true, canal: 'instagram', configurado: instagram.activo,
    firma: instagram.secretoApp ? 'exigida' : 'no exigida',
  });
}

export async function POST(peticion: Request) {
  const crudo = await peticion.text();

  const firma = firmaValida(crudo, peticion.headers, instagram.secretoApp);
  if (!firma.valida) {
    return NextResponse.json({ error: firma.motivo }, { status: 401 });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(crudo);
  } catch {
    return NextResponse.json({ ok: true, nota: 'Cuerpo ilegible, descartado.' });
  }

  const mensajes = extraerMensajes(payload);
  if (mensajes.length === 0) {
    // Reacciones, «visto», ecos del propio bot: no son preguntas.
    return NextResponse.json({ ok: true, mensajes: 0 });
  }

  const resultados = [];
  for (const m of mensajes) {
    try {
      const r = await atender('instagram', m.remitente, m.texto);
      if (r.texto) await responderPorInstagram(m.remitente, r.texto);
      resultados.push({ resultado: r.resultado });
    } catch (e) {
      // Se intenta avisar a quien preguntó; si eso también falla, se deja
      // constancia en el registro y se sigue con los demás mensajes.
      resultados.push({
        resultado: 'error',
        motivo: e instanceof Error ? e.message : 'desconocido',
      });
      try {
        await responderPorInstagram(m.remitente, 'Ahora mismo no puedo responder. Inténtalo en un rato.');
      } catch { /* sin nada más que hacer */ }
    }
  }

  return NextResponse.json({ ok: true, mensajes: mensajes.length, resultados });
}
