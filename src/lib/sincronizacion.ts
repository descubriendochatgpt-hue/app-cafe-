'use client';

/**
 * Sincronización de la cola.
 *
 * El orden importa y es siempre el mismo: **primero se guarda en el móvil,
 * después se intenta subir**. Nunca al revés. Si se intentara subir primero,
 * una venta hecha en un mercado sin cobertura se perdería en el momento justo
 * en el que más falta hace que no se pierda.
 *
 * Como cada operación lleva su UUID desde que nace, reintentar es inofensivo:
 * lo que ya estaba contabilizado vuelve marcado como idempotente.
 */
import {
  encolar, pendientes, quitarDeCola, marcarFallo, cuantasPendientes, type EnCola,
} from './almacenLocal';

export interface ResultadoSincronizacion {
  subidas: number;
  fallidas: number;
  bloqueadas: number;
  sinRed: boolean;
}

interface RespuestaOperacion {
  operacionId: string;
  estado: 'ok' | 'error';
  error?: { mensaje: string; sinStock: boolean; codigo: string };
}

/** Guarda la operación y, si hay red, intenta subirla en el acto. */
export async function registrar(
  tipo: string,
  datos: Record<string, unknown> & { operacionId: string },
): Promise<ResultadoSincronizacion> {
  await encolar({ operacionId: datos.operacionId, tipo, datos });
  return sincronizar();
}

let enMarcha = false;

export async function sincronizar(): Promise<ResultadoSincronizacion> {
  const vacio = { subidas: 0, fallidas: 0, bloqueadas: 0, sinRed: false };

  // Dos pestañas abiertas no deben subir la misma cola a la vez. Aunque lo
  // hicieran no se duplicaría nada (para eso está el UUID), pero sí se
  // gastaría batería y datos para nada.
  if (enMarcha) return vacio;
  if (typeof navigator !== 'undefined' && !navigator.onLine) return { ...vacio, sinRed: true };

  enMarcha = true;
  try {
    const cola = await pendientes();
    if (cola.length === 0) return vacio;

    // Se sube en tandas: una feria entera puede dejar cientos de operaciones.
    let subidas = 0, fallidas = 0, bloqueadas = 0;
    for (let i = 0; i < cola.length; i += 50) {
      const tanda = cola.slice(i, i + 50);
      const r = await subirTanda(tanda);
      subidas += r.subidas; fallidas += r.fallidas; bloqueadas += r.bloqueadas;
      if (r.sinRed) return { subidas, fallidas, bloqueadas, sinRed: true };
    }
    return { subidas, fallidas, bloqueadas, sinRed: false };
  } finally {
    enMarcha = false;
  }
}

async function subirTanda(tanda: EnCola[]): Promise<ResultadoSincronizacion> {
  let respuesta: Response;
  try {
    respuesta = await fetch('/api/operaciones', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        operaciones: tanda.map((o) => ({ tipo: o.tipo, datos: o.datos })),
      }),
    });
  } catch {
    // Se cayó la red a mitad. La cola se queda como estaba.
    return { subidas: 0, fallidas: tanda.length, bloqueadas: 0, sinRed: true };
  }

  if (respuesta.status === 401) {
    // Sesión caducada: no es culpa de las operaciones, se conservan intactas.
    return { subidas: 0, fallidas: tanda.length, bloqueadas: 0, sinRed: false };
  }

  if (!respuesta.ok && respuesta.status !== 207) {
    for (const op of tanda) {
      await marcarFallo(op.operacionId, `El servidor respondió ${respuesta.status}`, false);
    }
    return { subidas: 0, fallidas: tanda.length, bloqueadas: 0, sinRed: false };
  }

  const cuerpo = (await respuesta.json()) as { resultados: RespuestaOperacion[] };
  let subidas = 0, fallidas = 0, bloqueadas = 0;

  for (const r of cuerpo.resultados) {
    if (r.estado === 'ok') {
      await quitarDeCola(r.operacionId);
      subidas++;
      continue;
    }

    // Reintentar no va a arreglar que no hubiera stock, ni que el lote no
    // exista: eso necesita que alguien decida. Se aparta en vez de dar
    // vueltas para siempre.
    const definitivo = r.error?.sinStock === true
      || r.error?.codigo === 'PGRST202'
      || /no existe/i.test(r.error?.mensaje ?? '');

    await marcarFallo(r.operacionId, r.error?.mensaje ?? 'Error desconocido', definitivo);
    if (definitivo) bloqueadas++; else fallidas++;
  }

  return { subidas, fallidas, bloqueadas, sinRed: false };
}

export { cuantasPendientes };
