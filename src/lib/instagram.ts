/**
 * Bot de consulta por mensaje directo de Instagram.
 *
 * Lo que hay que saber antes de configurarlo:
 *
 *   · Hace falta una cuenta PROFESIONAL (empresa o creador) enlazada a una
 *     página de Facebook, una app de Meta y **revisión de Meta** para el
 *     permiso de mensajes. Es la misma fricción que llevó a descartar la
 *     Cloud API de WhatsApp para los pedidos, pero aquí compensa: son cuatro
 *     personas preguntando, no cientos de clientes pidiendo.
 *
 *   · A una cuenta de Instagram le escribe CUALQUIERA. Por eso el bot no
 *     responde a quien no esté autorizado, y autorizarse exige un código de
 *     un solo uso generado desde dentro de la aplicación.
 */
import { createHmac, timingSafeEqual } from 'node:crypto';

const GRAPH = 'https://graph.facebook.com/v21.0';

const v = (n: string) => (process.env[n] ?? '').trim();

export const instagram = {
  get activo(): boolean { return !!v('INSTAGRAM_ACCESS_TOKEN') && !!v('INSTAGRAM_CUENTA_ID'); },
  get token(): string { return v('INSTAGRAM_ACCESS_TOKEN'); },
  get cuenta(): string { return v('INSTAGRAM_CUENTA_ID'); },
  get secretoApp(): string { return v('INSTAGRAM_APP_SECRET'); },
  get tokenVerificacion(): string { return v('INSTAGRAM_VERIFY_TOKEN'); },
};

/* ─────────────────────────── Firma del envío ─────────────────────────── */

export function firmaValida(cuerpoCrudo: string, cabeceras: Headers, secreto: string):
  { valida: boolean; motivo?: string } {
  if (!secreto) return { valida: true };

  const recibida = cabeceras.get('x-hub-signature-256');
  if (!recibida) return { valida: false, motivo: 'El envío no trae firma.' };

  const esperada = 'sha256=' + createHmac('sha256', secreto).update(cuerpoCrudo, 'utf8').digest('hex');
  const a = Buffer.from(recibida.trim());
  const b = Buffer.from(esperada);
  if (a.length !== b.length) return { valida: false, motivo: 'La firma no coincide.' };

  return timingSafeEqual(a, b)
    ? { valida: true }
    : { valida: false, motivo: 'La firma no coincide con el secreto de la app.' };
}

/* ─────────────────────────── Lectura del envío ─────────────────────────── */

export interface MensajeEntrante {
  remitente: string;
  texto: string;
  id: string;
}

interface Envio {
  object?: string;
  entry?: {
    messaging?: {
      sender?: { id?: string };
      message?: { mid?: string; text?: string; is_echo?: boolean; is_deleted?: boolean };
    }[];
  }[];
}

/**
 * Saca los mensajes de texto de una persona.
 *
 * Se descartan los ecos —Meta devuelve lo que manda el propio bot— porque si
 * no, el bot se respondería a sí mismo en bucle. También se ignoran
 * reacciones, «visto» y mensajes borrados: no son preguntas.
 */
export function extraerMensajes(payload: unknown): MensajeEntrante[] {
  const p = payload as Envio;
  const fuera: MensajeEntrante[] = [];

  for (const entrada of p?.entry ?? []) {
    for (const m of entrada.messaging ?? []) {
      const texto = m.message?.text?.trim();
      const remitente = m.sender?.id;
      if (!texto || !remitente) continue;
      if (m.message?.is_echo || m.message?.is_deleted) continue;
      fuera.push({ remitente, texto, id: m.message?.mid ?? `${remitente}-${texto.length}` });
    }
  }
  return fuera;
}

/** ¿El mensaje es un código de alta? Seis caracteres del alfabeto sin ambigüedades. */
export function esCodigo(texto: string): string | null {
  const limpio = texto.trim().toUpperCase().replace(/\s+/g, '');
  return /^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/.test(limpio) ? limpio : null;
}

/* ─────────────────────────── Respuesta ─────────────────────────── */

/**
 * Instagram corta los mensajes largos, así que se parte por líneas en vez de
 * dejar que los trunque por la mitad de una palabra.
 */
const LARGO_MAXIMO = 900;

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
  return trozos.slice(0, 4);   // cuatro mensajes seguidos ya son demasiados
}

export async function responderPorInstagram(destinatario: string, texto: string): Promise<void> {
  if (!instagram.activo) throw new Error('Instagram no está configurado.');

  for (const trozo of trocear(texto)) {
    const r = await fetch(`${GRAPH}/${instagram.cuenta}/messages`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${instagram.token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ recipient: { id: destinatario }, message: { text: trozo } }),
      signal: AbortSignal.timeout(15_000),
    });

    if (!r.ok) {
      throw new Error(`Instagram respondió ${r.status}: ${(await r.text()).slice(0, 200)}`);
    }
  }
}
