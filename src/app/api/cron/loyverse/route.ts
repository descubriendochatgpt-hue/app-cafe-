/**
 * Consulta periódica de Loyverse: la red de seguridad del webhook.
 *
 * Un webhook se pierde más a menudo de lo que parece —un despliegue a mitad,
 * un corte de red, una caída de unos minutos— y una venta perdida no se
 * detecta sola: simplemente el stock deja de cuadrar. Preguntar cada pocos
 * minutos cierra ese agujero, y como todo entra por número de recibo, un
 * recibo que llegue por las dos vías se contabiliza una sola vez.
 *
 * También es el único camino si el plan contratado no incluye webhooks.
 */
import { NextResponse } from 'next/server';
import { comoSistema } from '@/lib/sistema';
import { guardarEvento, procesarCola, operacionIdDe, type EventoEnCola } from '@/lib/ingesta';
import { loyverse as config } from '@/lib/integraciones';
import { traerRecibos, procesarRecibo, type Recibo } from '@/lib/loyverse';
import { autorizada } from '@/lib/cron';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

export async function GET(peticion: Request) {
  if (!autorizada(peticion)) {
    return NextResponse.json({ error: 'No autorizada.' }, { status: 401 });
  }
  if (!config.activo) {
    return NextResponse.json({ ok: true, nota: 'Loyverse no está configurado.' });
  }

  const db = await comoSistema();

  // Desde dónde mirar. La primera vez, unos días hacia atrás; después, desde
  // el último recibo traído, con un solape de cinco minutos para no perder
  // nada que se creara justo en el corte.
  const { data: parametros } = await db
    .from('parametros').select('clave, valor')
    .in('clave', ['loyverse_ultima_sincronizacion', 'loyverse_dias_iniciales']);

  const mapa = new Map((parametros ?? []).map((p) => [p.clave, p.valor]));
  const ultima = mapa.get('loyverse_ultima_sincronizacion');
  const dias = Number(mapa.get('loyverse_dias_iniciales') ?? 7);

  const desde = ultima
    ? new Date(new Date(ultima).getTime() - 5 * 60_000).toISOString()
    : new Date(Date.now() - dias * 86_400_000).toISOString();

  let traidos = 0, nuevos = 0, cursor: string | null = null, vueltas = 0;
  let masReciente = ultima ?? desde;

  try {
    do {
      const pagina = await traerRecibos({ desde, cursor });
      cursor = pagina.cursor;
      vueltas++;

      for (const recibo of pagina.recibos) {
        traidos++;
        const { nuevo } = await guardarEvento(db, {
          canal: 'loyverse', tipo: 'receipt',
          origenId: recibo.receipt_number, payload: recibo,
        });
        if (nuevo) nuevos++;

        const cuando = recibo.created_at ?? recibo.receipt_date;
        if (cuando && cuando > masReciente) masReciente = cuando;
      }
      // Tope de seguridad: si hay meses de atraso, se recupera en varias
      // vueltas en vez de agotar el tiempo de la función y no guardar nada.
    } while (cursor && vueltas < 8);
  } catch (e) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : 'Fallo consultando Loyverse', traidos, nuevos },
      { status: 502 },
    );
  }

  // La marca de agua solo avanza si la consulta terminó bien. Si falló a
  // mitad, la próxima vuelta repite el tramo: repetir es inofensivo, saltarse
  // recibos no.
  if (traidos > 0) {
    await db.rpc('fijar_parametro', {
      p_clave: 'loyverse_ultima_sincronizacion', p_valor: masReciente,
    });
  }

  const resumen = await procesarCola(db, 'loyverse', (evento) => procesar(db, evento));

  return NextResponse.json({
    ok: true, desde, traidos, nuevos,
    procesados: resumen.procesados, fallidos: resumen.fallidos,
    detalles: resumen.detalles.filter((d) => d.estado === 'error'),
  });
}

async function procesar(
  db: Awaited<ReturnType<typeof comoSistema>>,
  evento: EventoEnCola,
): Promise<{ operacionId: string }> {
  const operacionId = await operacionIdDe('loyverse', evento.origen_id);
  await procesarRecibo(db, evento.payload as Recibo, {
    ubicacion: config.ubicacion, operacionId, eventoId: evento.evento_id,
  });
  return { operacionId };
}
