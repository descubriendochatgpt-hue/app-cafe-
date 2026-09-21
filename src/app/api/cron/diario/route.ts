/**
 * Todo el mantenimiento, en una sola pasada diaria.
 *
 * POR QUÉ EXISTE ESTA RUTA
 *
 * El plan gratuito de Vercel permite UNA tarea programada al día. Este
 * proyecto tiene cuatro cosas que hacer periódicamente, así que o se
 * renuncia a tres o se hacen las cuatro de una vez. Se hacen de una vez.
 *
 * QUÉ SIGNIFICA ESO DE VERDAD
 *
 * Con una sola pasada al día, las tareas programadas dejan de ser el camino
 * por el que entran las ventas y pasan a ser solo la red de seguridad. El
 * camino son los webhooks, que son inmediatos y no cuestan nada. Sin
 * webhooks configurados, una venta tardaría hasta un día en verse, y eso
 * incumple lo que se pidió: que se vea en menos de un minuto.
 *
 * O sea: con plan gratuito, los webhooks NO son opcionales.
 *
 * EL ORDEN NO ES CASUAL
 *
 *   1. Traer las ventas que el webhook no trajo.
 *   2. Reintentar lo que quedó atascado.
 *   3. Publicar el stock en la tienda — después de 1 y 2, para publicar la
 *      cifra de después de las ventas y no la de antes.
 *   4. Mandar el correo — el último, para que cuente cómo quedó todo.
 *
 * Y NINGÚN PASO PUEDE TUMBAR A LOS DEMÁS
 *
 * Si Loyverse está caído, el correo tiene que salir igual: precisamente ese
 * día es cuando hace falta que avise. Cada paso se captura por separado.
 */
import { NextResponse } from 'next/server';
import { autorizada } from '@/lib/cron';
import { GET as tareaLoyverse } from '../loyverse/route';
import { GET as tareaEventos } from '../eventos/route';
import { GET as tareaWoocommerce } from '../woocommerce/route';
import { GET as tareaAvisos } from '../avisos/route';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

/** Margen que se le reserva al correo pase lo que pase, en milisegundos. */
const RESERVA_CORREO = 12_000;

type Tarea = (p: Request) => Promise<Response>;

export async function GET(peticion: Request) {
  if (!autorizada(peticion)) {
    return NextResponse.json({ error: 'No autorizada.' }, { status: 401 });
  }

  const arranque = Date.now();
  const limite = (maxDuration * 1000) - RESERVA_CORREO;
  const resultado: Record<string, unknown> = {};

  async function paso(nombre: string, tarea: Tarea, saltable: boolean) {
    // El correo nunca se salta. Lo demás sí, si ya no queda tiempo: más vale
    // recuperar parte hoy y el resto mañana que agotar el tiempo de la
    // función y que no quede constancia de nada.
    if (saltable && Date.now() - arranque > limite) {
      resultado[nombre] = { saltado: 'sin tiempo en esta pasada' };
      return;
    }
    try {
      const r = await tarea(peticion);
      resultado[nombre] = await r.json();
    } catch (e) {
      resultado[nombre] = { error: e instanceof Error ? e.message : 'falló' };
    }
  }

  await paso('loyverse', tareaLoyverse, true);
  await paso('eventos', tareaEventos, true);
  await paso('woocommerce', tareaWoocommerce, true);
  await paso('avisos', tareaAvisos, false);

  return NextResponse.json({ ok: true, segundos: (Date.now() - arranque) / 1000, ...resultado });
}
