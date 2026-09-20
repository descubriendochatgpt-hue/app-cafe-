/**
 * Entrada de webhooks de Loyverse.
 *
 * Lo primero es guardar el recibo crudo; lo segundo, intentar procesarlo.
 * Si el procesamiento falla, se responde 200 de todos modos: el hecho ya
 * está guardado y la cola lo reintentará. Responder un error haría que
 * Loyverse reenviara indefinidamente algo que ya tenemos.
 *
 * Lo único que sí se rechaza es un envío sin firma válida.
 */
import { NextResponse } from 'next/server';
import { comoSistema } from '@/lib/sistema';
import { guardarEvento, operacionIdDe } from '@/lib/ingesta';
import { loyverse as config } from '@/lib/integraciones';
import { firmaValida, extraerRecibos, procesarRecibo } from '@/lib/loyverse';

export const dynamic = 'force-dynamic';

/** Algunos paneles comprueban que la URL existe antes de guardarla. */
export function GET() {
  return NextResponse.json({
    ok: true,
    canal: 'loyverse',
    configurado: config.activo,
    firma: config.secretoWebhook ? 'exigida' : 'no exigida',
  });
}

export async function POST(peticion: Request) {
  if (!config.activo) {
    return NextResponse.json(
      { error: 'Loyverse no está configurado. Rellena LOYVERSE_ACCESS_TOKEN.' },
      { status: 503 },
    );
  }

  // El cuerpo CRUDO, sin volver a serializar: reserializar cambiaría los
  // espacios y la firma dejaría de cuadrar.
  const crudo = await peticion.text();

  const firma = firmaValida(crudo, peticion.headers, config.secretoWebhook);
  if (!firma.valida) {
    return NextResponse.json({ error: firma.motivo }, { status: 401 });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(crudo);
  } catch {
    return NextResponse.json({ error: 'El cuerpo no es JSON válido.' }, { status: 400 });
  }

  const recibos = extraerRecibos(payload);
  if (recibos.length === 0) {
    // No es un error: Loyverse manda avisos de otros objetos que no nos tocan.
    return NextResponse.json({ ok: true, recibos: 0, nota: 'Sin recibos en el envío.' });
  }

  const db = await comoSistema();
  const resultados = [];

  for (const recibo of recibos) {
    try {
      const { eventoId, nuevo } = await guardarEvento(db, {
        canal: 'loyverse',
        tipo: 'receipt',
        origenId: recibo.receipt_number,
        payload: recibo,
      });

      if (!nuevo) {
        resultados.push({ recibo: recibo.receipt_number, estado: 'repetido' });
        continue;
      }

      try {
        const operacionId = await operacionIdDe('loyverse', recibo.receipt_number);
        const r = await procesarRecibo(db, recibo, {
          ubicacion: config.ubicacion, operacionId, eventoId,
        });
        await db.rpc('evento_procesado', { p_evento_id: eventoId, p_operacion_id: operacionId });
        resultados.push({ recibo: recibo.receipt_number, estado: r.tipo });
      } catch (e) {
        // Guardado queda; la cola lo reintentará con espera creciente.
        const mensaje = e instanceof Error ? e.message : 'Error desconocido';
        await db.rpc('evento_fallido', { p_evento_id: eventoId, p_error: mensaje });
        resultados.push({ recibo: recibo.receipt_number, estado: 'en cola', motivo: mensaje });
      }
    } catch (e) {
      // Ni siquiera se pudo guardar: aquí sí conviene que Loyverse reenvíe.
      return NextResponse.json(
        { error: e instanceof Error ? e.message : 'No se pudo guardar el evento.' },
        { status: 500 },
      );
    }
  }

  return NextResponse.json({ ok: true, recibos: recibos.length, resultados });
}
