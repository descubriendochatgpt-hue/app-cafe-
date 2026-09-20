/**
 * Entrada de webhooks de WooCommerce.
 *
 * Lo mismo que en Loyverse: guardar el pedido crudo primero, procesarlo
 * después, y responder 200 aunque el proceso falle. El hecho ya está a salvo
 * y la cola lo reintentará; responder un error solo haría que WooCommerce
 * reenviara indefinidamente algo que ya tenemos.
 *
 * La diferencia está en la clave de idempotencia: el mismo pedido genera
 * varios avisos a lo largo de su vida (creado, pagado, enviado), así que el
 * evento se indexa por pedido Y estado. Indexar solo por pedido haría que el
 * aviso de «enviado» se descartara como repetido del de «pagado», y el stock
 * nunca llegaría a descontarse.
 */
import { NextResponse } from 'next/server';
import { comoSistema } from '@/lib/sistema';
import { guardarEvento } from '@/lib/ingesta';
import { woocommerce as config } from '@/lib/integraciones';
import {
  firmaValida, esPing, procesarPedido, pasoPara, referenciaDe, type Pedido,
} from '@/lib/woocommerce';

export const dynamic = 'force-dynamic';

export function GET() {
  return NextResponse.json({
    ok: true,
    canal: 'woocommerce',
    configurado: config.activo,
    firma: config.secretoWebhook ? 'exigida' : 'no exigida',
  });
}

export async function POST(peticion: Request) {
  if (!config.activo) {
    return NextResponse.json(
      { error: 'WooCommerce no está configurado. Rellena sus claves en el fichero de integraciones.' },
      { status: 503 },
    );
  }

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

  // WooCommerce comprueba la URL con un ping antes de guardar el webhook.
  if (esPing(peticion.headers, payload)) {
    return NextResponse.json({ ok: true, nota: 'Ping recibido.' });
  }

  const pedido = payload as Pedido;
  if (typeof pedido?.id !== 'number') {
    return NextResponse.json({ ok: true, nota: 'El envío no es un pedido.' });
  }

  const paso = pasoPara(pedido.status);
  if (paso === 'ignorar') {
    // Un carrito pendiente de pago no compromete nada. Se responde bien para
    // que WooCommerce no lo reintente, pero no se guarda ruido en la cola.
    return NextResponse.json({ ok: true, pedido: pedido.id, estado: pedido.status, paso });
  }

  const db = await comoSistema();

  try {
    const { eventoId, nuevo } = await guardarEvento(db, {
      canal: 'woocommerce',
      // El estado forma parte de la clave: el mismo pedido pasa por varias
      // etapas y cada una es un hecho distinto que hay que atender.
      tipo: `order.${String(pedido.status ?? 'desconocido')}`,
      origenId: referenciaDe(pedido),
      payload: pedido,
    });

    if (!nuevo) {
      return NextResponse.json({ ok: true, pedido: pedido.id, estado: 'repetido' });
    }

    try {
      const r = await procesarPedido(db, pedido, {
        ubicacion: config.ubicacion, eventoId,
      });
      await db.rpc('evento_procesado', { p_evento_id: eventoId, p_operacion_id: null });
      return NextResponse.json({ ok: true, pedido: pedido.id, paso: r.paso });
    } catch (e) {
      const mensaje = e instanceof Error ? e.message : 'Error desconocido';
      await db.rpc('evento_fallido', { p_evento_id: eventoId, p_error: mensaje });
      return NextResponse.json({ ok: true, pedido: pedido.id, estado: 'en cola', motivo: mensaje });
    }
  } catch (e) {
    // Ni siquiera se pudo guardar: aquí sí conviene que WooCommerce reenvíe.
    return NextResponse.json(
      { error: e instanceof Error ? e.message : 'No se pudo guardar el evento.' },
      { status: 500 },
    );
  }
}
