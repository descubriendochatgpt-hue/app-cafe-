/**
 * Reintento de la cola, para todos los canales.
 *
 * Aquí acaban los eventos que fallaron al llegar: un SKU sin mapear, la base
 * ocupada, un despliegue justo en ese segundo. Se reintentan con espera
 * creciente y, si tras ocho intentos siguen fallando, dejan de ser un
 * problema técnico y pasan a la pantalla de conciliación.
 */
import { NextResponse } from 'next/server';
import { comoSistema } from '@/lib/sistema';
import { procesarCola, operacionIdDe, type EventoEnCola } from '@/lib/ingesta';
import { loyverse as configLoyverse, woocommerce as configWoo } from '@/lib/integraciones';
import { procesarRecibo, type Recibo } from '@/lib/loyverse';
import { procesarPedido, type Pedido } from '@/lib/woocommerce';
import { autorizada } from '@/lib/cron';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

export async function GET(peticion: Request) {
  if (!autorizada(peticion)) {
    return NextResponse.json({ error: 'No autorizada.' }, { status: 401 });
  }

  const db = await comoSistema();
  const resultado: Record<string, unknown> = {};

  if (configLoyverse.activo) {
    resultado.loyverse = await procesarCola(db, 'loyverse', async (evento: EventoEnCola) => {
      const operacionId = await operacionIdDe('loyverse', evento.origen_id);
      await procesarRecibo(db, evento.payload as Recibo, {
        ubicacion: configLoyverse.ubicacion, operacionId, eventoId: evento.evento_id,
      });
      return { operacionId };
    });
  }

  if (configWoo.activo) {
    resultado.woocommerce = await procesarCola(db, 'woocommerce', async (evento: EventoEnCola) => {
      await procesarPedido(db, evento.payload as Pedido, {
        ubicacion: configWoo.ubicacion, eventoId: evento.evento_id,
      });
      // El identificador de operación lo decide cada paso del pedido dentro
      // de procesarPedido, así que aquí no hay uno solo que devolver.
      return { operacionId: null };
    });
  }

  // Los descuadres entre el libro y la proyección no deberían existir nunca.
  // Comprobarlo cuesta una consulta y es la diferencia entre enterarse hoy o
  // enterarse cuando alguien nota que el stock no cuadra.
  const { data: descuadres } = await db.rpc('verificar_saldos_publico');
  resultado.descuadres = Array.isArray(descuadres) ? descuadres.length : 0;

  return NextResponse.json({ ok: true, ...resultado });
}
