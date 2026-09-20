/**
 * Bot de consulta por Telegram.
 *
 * Se eligió Telegram sobre Instagram por una razón práctica: con @BotFather
 * se obtiene un token y funciona en dos minutos, sin cuenta profesional, sin
 * página de Facebook y sin esperar la revisión de Meta.
 *
 * Y por una de fondo: un mensaje de Telegram es privado por naturaleza. Una
 * cuenta de Instagram es un buzón público al que escribe cualquier cliente,
 * lo que convertía «a quién respondo» en el problema principal. Aquí sigue
 * habiendo autorización —la misma—, pero el canal no invita al ruido.
 */
import { createHmac, timingSafeEqual } from 'node:crypto';

const API = 'https://api.telegram.org';

const v = (n: string) => (process.env[n] ?? '').trim();

export const telegram = {
  get activo(): boolean { return !!v('TELEGRAM_BOT_TOKEN'); },
  get token(): string { return v('TELEGRAM_BOT_TOKEN'); },
  /** Telegram lo devuelve en cada envío; sirve para saber que viene de él. */
  get secretoWebhook(): string { return v('TELEGRAM_WEBHOOK_SECRET'); },
  get usuario(): string { return v('TELEGRAM_BOT_USUARIO').replace(/^@/, ''); },
};

/* ─────────────────────────── Autenticidad del envío ───────────────────────────
   Telegram no firma el cuerpo: devuelve, en una cabecera, el mismo secreto
   que se le dio al registrar el webhook. Basta, porque la URL es https y el
   secreto no viaja a ningún otro sitio. Aun así se compara en tiempo
   constante: comparar cadenas con === filtra por dónde empiezan a diferir.
   ──────────────────────────────────────────────────────────────── */

export function envioAutentico(cabeceras: Headers, secreto: string):
  { valido: boolean; motivo?: string } {
  if (!secreto) return { valido: true };

  const recibido = cabeceras.get('x-telegram-bot-api-secret-token');
  if (!recibido) return { valido: false, motivo: 'El envío no trae el secreto acordado.' };

  const a = Buffer.from(recibido);
  const b = Buffer.from(secreto);
  if (a.length !== b.length) return { valido: false, motivo: 'El secreto no coincide.' };

  return timingSafeEqual(a, b)
    ? { valido: true }
    : { valido: false, motivo: 'El secreto no coincide con el configurado.' };
}

/** Sin uso hoy; queda por si Telegram añade firma del cuerpo. */
export function firmaHmac(cuerpo: string, secreto: string): string {
  return createHmac('sha256', secreto).update(cuerpo, 'utf8').digest('hex');
}

/* ─────────────────────────── Lectura del envío ─────────────────────────── */

export interface MensajeEntrante {
  chat: number;
  remitente: string;
  texto: string;
  nombre: string | null;
  alias: string | null;
}

interface Actualizacion {
  update_id?: number;
  message?: {
    message_id?: number;
    from?: { id?: number; is_bot?: boolean; first_name?: string; username?: string };
    chat?: { id?: number; type?: string };
    text?: string;
  };
  edited_message?: unknown;
}

/**
 * Saca el mensaje de una persona, si lo hay.
 *
 * Se descarta todo lo demás a propósito:
 *
 *   · los mensajes de otros bots, que producirían bucles entre los dos;
 *   · los grupos y canales. Esto es lo importante: si alguien añade el bot a
 *     un grupo, cualquiera que esté dentro vería las respuestas aunque no
 *     esté autorizado. Solo se atiende en conversación privada;
 *   · las ediciones de mensajes ya enviados, que no son preguntas nuevas.
 */
export function extraerMensaje(payload: unknown): MensajeEntrante | null {
  const u = payload as Actualizacion;
  const m = u?.message;
  if (!m) return null;

  const texto = m.text?.trim();
  const id = m.from?.id;
  if (!texto || !id) return null;
  if (m.from?.is_bot) return null;
  if (m.chat?.type !== 'private') return null;

  return {
    chat: m.chat.id ?? id,
    remitente: String(id),
    texto,
    nombre: m.from?.first_name ?? null,
    alias: m.from?.username ?? null,
  };
}

/**
 * El código de alta puede llegar de dos maneras: escrito a mano, o dentro de
 * `/start CODIGO`, que es lo que manda Telegram al abrir el enlace de alta.
 */
export function esCodigo(texto: string): string | null {
  const limpio = texto.trim().replace(/^\/start\s*/i, '').toUpperCase().replace(/\s+/g, '');
  return /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/.test(limpio) ? limpio : null;
}

/** `/stock etiopía` y `stock etiopía` son la misma pregunta. */
export function limpiarComando(texto: string): string {
  return texto.trim().replace(/^\/([a-z_]+)(@\w+)?/i, '$1').trim();
}

/* ─────────────────────────── Respuesta ─────────────────────────── */

/** Telegram corta a 4096 caracteres; se parte por líneas antes de llegar. */
const LARGO_MAXIMO = 3500;

export function trocear(texto: string): string[] {
  if (texto.length <= LARGO_MAXIMO) return [texto];

  const trozos: string[] = [];
  let actual = '';
  for (const linea of texto.split('\n')) {
    if (actual.length + linea.length + 1 > LARGO_MAXIMO) {
      if (actual) trozos.push(actual.trimEnd());
      actual = '';
    }
    actual += `${linea}\n`;
  }
  if (actual.trim()) trozos.push(actual.trimEnd());
  return trozos.slice(0, 4);
}

async function llamar(metodo: string, cuerpo: unknown): Promise<unknown> {
  if (!telegram.activo) throw new Error('Telegram no está configurado.');

  const r = await fetch(`${API}/bot${telegram.token}/${metodo}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(cuerpo),
    signal: AbortSignal.timeout(15_000),
  });

  const datos = await r.json() as { ok?: boolean; description?: string; result?: unknown };
  if (!r.ok || !datos.ok) {
    throw new Error(`Telegram: ${datos.description ?? `respondió ${r.status}`}`);
  }
  return datos.result;
}

export async function responderPorTelegram(chat: number, texto: string): Promise<void> {
  for (const trozo of trocear(texto)) {
    await llamar('sendMessage', {
      chat_id: chat,
      text: trozo,
      // Sin formato: las respuestas llevan nombres de café con guiones y
      // paréntesis, y con Markdown activado Telegram rechaza el mensaje
      // entero por un carácter suelto sin escapar.
      disable_web_page_preview: true,
    });
  }
}

/* ─────────────────────────── Puesta en marcha ─────────────────────────── */

export interface EstadoWebhook {
  url?: string;
  pending_update_count?: number;
  last_error_message?: string;
  last_error_date?: number;
}

/** Registra la URL en Telegram. Evita tener que hacerlo con curl a mano. */
export async function registrarWebhook(url: string): Promise<void> {
  await llamar('setWebhook', {
    url,
    secret_token: telegram.secretoWebhook || undefined,
    // Solo mensajes: ni ediciones, ni pulsaciones de botones, ni nada más.
    allowed_updates: ['message'],
    drop_pending_updates: true,
  });
}

export async function estadoWebhook(): Promise<EstadoWebhook> {
  return await llamar('getWebhookInfo', {}) as EstadoWebhook;
}

export async function quienEsElBot(): Promise<{ username?: string; first_name?: string }> {
  return await llamar('getMe', {}) as { username?: string; first_name?: string };
}
