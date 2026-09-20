/**
 * Mecánica común de ingesta, compartida por todos los conectores.
 *
 * El orden es siempre: **guardar el evento crudo primero, procesarlo
 * después**. Si el procesamiento falla —un SKU sin mapear, la base caída, un
 * despliegue a mitad—, el hecho no se pierde: queda en la cola y se reintenta.
 * Procesar antes de guardar convertiría cualquier fallo en una venta perdida.
 */
import type { SupabaseClient } from '@supabase/supabase-js';

export interface EventoGuardado {
  eventoId: string;
  nuevo: boolean;
  estado: string;
}

export async function guardarEvento(
  db: SupabaseClient,
  e: { canal: string; tipo: string; origenId: string; payload: unknown },
): Promise<EventoGuardado> {
  const { data, error } = await db.rpc('recibir_evento', {
    p_canal: e.canal,
    p_tipo: e.tipo,
    p_origen_id: e.origenId,
    p_payload: e.payload,
  });
  if (error) throw new Error(`No se pudo guardar el evento: ${error.message}`);
  const r = data as { evento_id: string; nuevo: boolean; estado: string };
  return { eventoId: r.evento_id, nuevo: r.nuevo, estado: r.estado };
}

export interface EventoEnCola {
  evento_id: string;
  canal: string;
  tipo: string;
  origen_id: string;
  payload: unknown;
  intentos: number;
}

export interface ResumenProceso {
  procesados: number;
  fallidos: number;
  detalles: { origenId: string; estado: 'ok' | 'error'; mensaje?: string }[];
}

/**
 * Toma los eventos que toca procesar y los pasa por `procesar`.
 *
 * Un evento que falla no detiene a los demás: la venta de las 12:04 no tiene
 * por qué quedarse esperando a que alguien mapee un artículo de la de las 12:02.
 */
export async function procesarCola(
  db: SupabaseClient,
  canal: string,
  procesar: (evento: EventoEnCola) => Promise<{ operacionId?: string | null }>,
  limite = 25,
): Promise<ResumenProceso> {
  const { data, error } = await db.rpc('tomar_eventos', { p_canal: canal, p_limite: limite });
  if (error) throw new Error(`No se pudo tomar la cola: ${error.message}`);

  const eventos = (data ?? []) as EventoEnCola[];
  const resumen: ResumenProceso = { procesados: 0, fallidos: 0, detalles: [] };

  for (const evento of eventos) {
    try {
      const { operacionId } = await procesar(evento);
      await db.rpc('evento_procesado', {
        p_evento_id: evento.evento_id,
        p_operacion_id: operacionId ?? null,
      });
      resumen.procesados++;
      resumen.detalles.push({ origenId: evento.origen_id, estado: 'ok' });
    } catch (e) {
      const mensaje = e instanceof Error ? e.message : 'Error desconocido';
      await db.rpc('evento_fallido', { p_evento_id: evento.evento_id, p_error: mensaje });
      resumen.fallidos++;
      resumen.detalles.push({ origenId: evento.origen_id, estado: 'error', mensaje });
    }
  }

  return resumen;
}

/**
 * Identificador de operación derivado del evento.
 *
 * Determinista a propósito: si el mismo recibo se procesa dos veces (un
 * reenvío, un reintento tras un fallo a medias), la operación es la misma y
 * la base la reconoce como ya contabilizada. Con un UUID al azar, cada
 * reintento crearía una venta nueva.
 */
export async function operacionIdDe(canal: string, origenId: string): Promise<string> {
  const datos = new TextEncoder().encode(`${canal}:${origenId}`);
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', datos));
  hash[6] = (hash[6]! & 0x0f) | 0x50;   // versión 5
  hash[8] = (hash[8]! & 0x3f) | 0x80;   // variante RFC 4122
  const h = [...hash.slice(0, 16)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}
