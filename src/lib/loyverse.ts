/**
 * Conector de Loyverse.
 *
 * Dos caminos de entrada que llevan al mismo sitio:
 *
 *   WEBHOOK  — tiempo real. Loyverse avisa al vender.
 *   CONSULTA — red de seguridad. Cada pocos minutos se pregunta por los
 *              recibos nuevos, por si se perdió un webhook (pasa: caídas,
 *              despliegues, cortes de red) o por si el plan contratado no
 *              incluye webhooks.
 *
 * Los dos escriben en `eventos_entrada` con el número de recibo como clave,
 * así que da igual que un recibo llegue por los dos: se contabiliza una vez.
 */
import { createHmac, timingSafeEqual } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import { loyverse as config } from './integraciones';

const API = 'https://api.loyverse.com/v1.0';

/* ─────────────────────────── Forma de los datos ─────────────────────────── */

export interface LineaRecibo {
  id?: string;
  item_id?: string;
  variant_id?: string;
  item_name?: string;
  variant_name?: string | null;
  sku?: string | null;
  quantity: number;
  price?: number | null;
  total_money?: number | null;
  total_discount?: number | null;
}

export interface Recibo {
  receipt_number: string;
  receipt_type?: 'SALE' | 'REFUND' | string;
  refund_for?: string | null;
  receipt_date?: string;
  created_at?: string;
  updated_at?: string;
  cancelled_at?: string | null;
  store_id?: string;
  customer_id?: string | null;
  total_money?: number;
  line_items?: LineaRecibo[];
  payments?: { name?: string; type?: string; money_amount?: number }[];
}

/* ─────────────────────────── Firma del webhook ───────────────────────────
   Loyverse firma cada envío con el secreto que muestra al crear el webhook.
   La cabecera exacta ha cambiado entre versiones de su documentación, así
   que se aceptan las variantes conocidas y se puede fijar una a mano con
   LOYVERSE_WEBHOOK_HEADER. La comprobación es sobre el CUERPO CRUDO: volver
   a serializar el JSON cambiaría los espacios y rompería la firma.
   ──────────────────────────────────────────────────────────────── */

const CABECERAS_FIRMA = [
  'x-loyverse-signature',
  'loyverse-signature',
  'x-signature',
  'x-hub-signature-256',
];

export function cabecerasFirmaPosibles(): string[] {
  const fijada = (process.env.LOYVERSE_WEBHOOK_HEADER ?? '').trim().toLowerCase();
  return fijada ? [fijada] : CABECERAS_FIRMA;
}

function iguales(a: string, b: string): boolean {
  const ba = Buffer.from(a), bb = Buffer.from(b);
  // Longitudes distintas ya no coinciden, pero se compara igual contra un
  // buffer del mismo tamaño para no filtrar la longitud por el tiempo.
  if (ba.length !== bb.length) return timingSafeEqual(ba, ba) && false;
  return timingSafeEqual(ba, bb);
}

export function firmaValida(
  cuerpoCrudo: string,
  cabeceras: Headers,
  secreto: string,
): { valida: boolean; motivo?: string } {
  if (!secreto) return { valida: true };   // sin secreto configurado no se exige

  let recibida: string | null = null;
  for (const nombre of cabecerasFirmaPosibles()) {
    const v = cabeceras.get(nombre);
    if (v) { recibida = v.trim(); break; }
  }
  if (!recibida) {
    return { valida: false, motivo: 'El envío no trae cabecera de firma.' };
  }

  // Algunos emisores prefijan el algoritmo: "sha256=abc…". Se quita SOLO si
  // el prefijo es un nombre de algoritmo conocido: el relleno del base64
  // también lleva '=' al final, y cortar por el primero que aparezca
  // destrozaría cualquier firma en base64.
  const sinPrefijo = recibida.replace(/^(?:sha256|sha1|hmac-sha256)=/i, '');
  const candidatos = [recibida, sinPrefijo];
  const hex = createHmac('sha256', secreto).update(cuerpoCrudo, 'utf8').digest('hex');
  const b64 = createHmac('sha256', secreto).update(cuerpoCrudo, 'utf8').digest('base64');

  for (const c of candidatos) {
    if (iguales(c.toLowerCase(), hex) || iguales(c, b64)) return { valida: true };
  }
  return { valida: false, motivo: 'La firma no coincide con el secreto configurado.' };
}

/* ─────────────────────────── Lectura del envío ───────────────────────────
   Se aceptan varias envolturas porque no todas las versiones del webhook
   mandan lo mismo, y porque la consulta periódica devuelve otra forma.
   Lo único que importa es sacar la lista de recibos. */

export function extraerRecibos(payload: unknown): Recibo[] {
  if (!payload || typeof payload !== 'object') return [];
  const p = payload as Record<string, unknown>;

  for (const clave of ['receipts', 'data', 'items']) {
    const v = p[clave];
    if (Array.isArray(v)) return v.filter(esRecibo);
  }
  if (esRecibo(p)) return [p as unknown as Recibo];
  return [];
}

function esRecibo(v: unknown): v is Recibo {
  return !!v && typeof v === 'object'
      && typeof (v as Recibo).receipt_number === 'string';
}

/* ─────────────────────────── Mapeo a SKU interno ───────────────────────────
   Con 20-30 referencias la tabla se mantiene a mano, como se acordó. Lo que
   no se tolera es que un código sin mapear pase desapercibido: la venta se
   queda en cola con su incidencia hasta que alguien la mapee, en vez de
   registrarse a medias.
   ──────────────────────────────────────────────────────────────── */

export interface Mapeo { codigo_externo: string; sku: string }

export interface LineaMapeada {
  sku: string;
  cantidad: number;
  precio_unit?: number;
}

export interface ResultadoMapeo {
  lineas: LineaMapeada[];
  sinMapear: { codigo: string; nombre: string; cantidad: number }[];
}

/** Claves por las que se intenta reconocer una línea, en orden de fiabilidad. */
export function clavesDe(linea: LineaRecibo): string[] {
  return [linea.variant_id, linea.sku, linea.item_id]
    .map((v) => (v ?? '').trim())
    .filter(Boolean);
}

export function mapearRecibo(recibo: Recibo, mapeo: Mapeo[]): ResultadoMapeo {
  const porCodigo = new Map(mapeo.map((m) => [m.codigo_externo, m.sku]));
  const lineas: LineaMapeada[] = [];
  const sinMapear: ResultadoMapeo['sinMapear'] = [];

  for (const l of recibo.line_items ?? []) {
    const cantidad = Math.abs(Number(l.quantity ?? 0));
    if (!cantidad) continue;

    const sku = clavesDe(l).map((c) => porCodigo.get(c)).find(Boolean);
    const nombre = [l.item_name, l.variant_name].filter(Boolean).join(' · ') || 'sin nombre';

    if (!sku) {
      sinMapear.push({ codigo: clavesDe(l)[0] ?? nombre, nombre, cantidad });
      continue;
    }

    // Se acumulan las líneas del mismo artículo: Loyverse puede partir una
    // venta en varias líneas y nuestro pedido las quiere juntas.
    const previa = lineas.find((x) => x.sku === sku);
    const precio = l.price ?? undefined;
    if (previa) previa.cantidad += cantidad;
    else lineas.push({ sku, cantidad, ...(precio !== undefined ? { precio_unit: precio } : {}) });
  }

  return { lineas, sinMapear };
}

/* ─────────────────────────── Proceso de un recibo ─────────────────────────── */

export class ErrorMapeo extends Error {
  constructor(readonly sinMapear: ResultadoMapeo['sinMapear']) {
    super(
      `Hay ${sinMapear.length} artículo(s) sin mapear: `
      + sinMapear.map((s) => `${s.nombre} (${s.codigo})`).join(', '),
    );
    this.name = 'ErrorMapeo';
  }
}

export function momentoDe(r: Recibo): string {
  const crudo = r.receipt_date ?? r.created_at ?? r.updated_at;
  const d = crudo ? new Date(crudo) : new Date();
  return Number.isNaN(d.getTime()) ? new Date().toISOString() : d.toISOString();
}

export function formaPagoDe(r: Recibo): string | null {
  return r.payments?.[0]?.name ?? r.payments?.[0]?.type ?? null;
}

export async function procesarRecibo(
  db: SupabaseClient,
  recibo: Recibo,
  opciones: { ubicacion: string; operacionId: string; eventoId?: string },
): Promise<{ tipo: 'venta' | 'devolucion' | 'cancelado'; resultado: unknown }> {
  const { data: mapeo, error: errorMapeo } = await db
    .from('mapeo_articulos')
    .select('codigo_externo, sku')
    .eq('canal', 'loyverse');
  if (errorMapeo) throw new Error(`No se pudo leer el mapeo: ${errorMapeo.message}`);

  const { lineas, sinMapear } = mapearRecibo(recibo, (mapeo ?? []) as Mapeo[]);

  // Un recibo anulado en el TPV no se deshace a ciegas: si ya se contabilizó,
  // revertirlo movería stock que quizá se recontó entretanto. Se deja anotado
  // para que lo mire una persona, y el evento se da por atendido para que no
  // entre en un bucle de reintentos que nunca va a resolver nada.
  if (recibo.cancelled_at) {
    await db.rpc('registrar_incidencia', {
      p_tipo: 'EVENTO_FALLIDO',
      p_canal: 'loyverse',
      p_referencia: recibo.receipt_number,
      p_detalle: {
        motivo: 'Recibo anulado en Loyverse',
        anulado_en: recibo.cancelled_at,
        que_hacer: 'Comprobar si la venta llegó a descontar stock y corregir con un ajuste.',
      },
      p_evento_id: opciones.eventoId ?? null,
    });
    return { tipo: 'cancelado', resultado: null };
  }

  if (sinMapear.length > 0) throw new ErrorMapeo(sinMapear);
  if (lineas.length === 0) throw new Error('El recibo no trae ninguna línea con cantidad.');

  const esDevolucion = String(recibo.receipt_type ?? '').toUpperCase() === 'REFUND';
  const cuando = momentoDe(recibo);

  if (esDevolucion) {
    const { data, error } = await db.rpc('registrar_devolucion', {
      p_operacion_id: opciones.operacionId,
      p_ubicacion_id: opciones.ubicacion,
      p_lineas: lineas.map((l) => ({ sku: l.sku, cantidad: l.cantidad })),
      p_venta_origen_id: recibo.refund_for ?? null,
      p_origen: 'loyverse',
      p_origen_id: recibo.receipt_number,
      p_ocurrido_en: cuando,
      p_nota: `Devolución en Loyverse${recibo.refund_for ? ` del recibo ${recibo.refund_for}` : ''}`,
    });
    if (error) throw new Error(error.message);
    return { tipo: 'devolucion', resultado: data };
  }

  const { data, error } = await db.rpc('registrar_venta', {
    p_operacion_id: opciones.operacionId,
    p_ubicacion_id: opciones.ubicacion,
    p_lineas: lineas,
    p_canal: 'Mostrador',
    p_origen: 'loyverse',
    p_origen_id: recibo.receipt_number,
    // La app no emite documentos fiscales: guarda la referencia del que ya
    // emitió Loyverse con su Verifactu.
    p_documento_fiscal: recibo.receipt_number,
    p_documento_fiscal_sistema: 'loyverse',
    p_forma_pago: formaPagoDe(recibo),
    p_ocurrido_en: cuando,
    p_evento_id: opciones.eventoId ?? null,
  });
  if (error) throw new Error(error.message);
  return { tipo: 'venta', resultado: data };
}

/* ─────────────────────────── Cliente de la API ─────────────────────────── */

export interface PaginaRecibos { recibos: Recibo[]; cursor: string | null }

export async function traerRecibos(opciones: {
  desde: string;
  cursor?: string | null;
  limite?: number;
}): Promise<PaginaRecibos> {
  if (!config.activo) throw new Error('Loyverse no está configurado.');

  const url = new URL(`${API}/receipts`);
  url.searchParams.set('created_at_min', opciones.desde);
  url.searchParams.set('limit', String(opciones.limite ?? 250));
  if (opciones.cursor) url.searchParams.set('cursor', opciones.cursor);

  const r = await fetch(url, {
    headers: { Authorization: `Bearer ${config.token}`, Accept: 'application/json' },
    // Sin esto, una caída de Loyverse deja la tarea colgada hasta el límite
    // de la función y se pierde la ventana de la siguiente ejecución.
    signal: AbortSignal.timeout(20_000),
  });

  if (r.status === 401) throw new Error('Loyverse rechaza el token: revísalo en el fichero de integraciones.');
  if (r.status === 429) throw new Error('Loyverse está limitando las peticiones. Se reintenta en la próxima vuelta.');
  if (!r.ok) throw new Error(`Loyverse respondió ${r.status}: ${(await r.text()).slice(0, 200)}`);

  const cuerpo = (await r.json()) as { receipts?: Recibo[]; cursor?: string | null };
  return { recibos: cuerpo.receipts ?? [], cursor: cuerpo.cursor ?? null };
}

/* ─────────────────────────── Catálogo de Loyverse ───────────────────────────
   Para la pantalla de mapeo: se traen sus artículos con sus variantes y se
   emparejan a mano con los SKU internos. Con 20-30 referencias es cosa de
   diez minutos, y hacerlo a mano evita un automatismo que se equivoque en
   silencio con dos cafés de nombre parecido.
   ──────────────────────────────────────────────────────────────── */

export interface VarianteLoyverse {
  variant_id: string;
  sku?: string | null;
  option1_value?: string | null;
  option2_value?: string | null;
  option3_value?: string | null;
}

export interface ArticuloLoyverse {
  id: string;
  item_name: string;
  variants?: VarianteLoyverse[];
}

export interface ArticuloPlano {
  /** Clave con la que se mapea: el identificador de variante, que es estable. */
  codigo: string;
  nombre: string;
  sku_loyverse: string | null;
}

export async function traerArticulos(): Promise<ArticuloPlano[]> {
  if (!config.activo) throw new Error('Loyverse no está configurado.');

  const planos: ArticuloPlano[] = [];
  let cursor: string | null = null;
  let vueltas = 0;

  do {
    const url = new URL(`${API}/items`);
    url.searchParams.set('limit', '250');
    if (cursor) url.searchParams.set('cursor', cursor);

    const r = await fetch(url, {
      headers: { Authorization: `Bearer ${config.token}`, Accept: 'application/json' },
      signal: AbortSignal.timeout(20_000),
    });
    if (r.status === 401) throw new Error('Loyverse rechaza el token: revísalo en el fichero de integraciones.');
    if (!r.ok) throw new Error(`Loyverse respondió ${r.status}`);

    const cuerpo = (await r.json()) as { items?: ArticuloLoyverse[]; cursor?: string | null };
    for (const item of cuerpo.items ?? []) {
      for (const v of item.variants ?? [{ variant_id: item.id }]) {
        const opciones = [v.option1_value, v.option2_value, v.option3_value]
          .filter(Boolean).join(' · ');
        planos.push({
          codigo: v.variant_id,
          nombre: opciones ? `${item.item_name} · ${opciones}` : item.item_name,
          sku_loyverse: v.sku ?? null,
        });
      }
    }
    cursor = cuerpo.cursor ?? null;
    vueltas++;
  } while (cursor && vueltas < 10);

  return planos.sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'));
}
