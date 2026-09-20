/**
 * Conector de WooCommerce.
 *
 * La diferencia de fondo con Loyverse: un recibo de TPV es un hecho cerrado,
 * pero un pedido web es una máquina de estados. El mismo pedido avisa al
 * crearse, al pagarse, al enviarse y al reembolsarse, y cada aviso trae el
 * pedido ENTERO. Contar cada aviso como una venta multiplicaría el stock que
 * sale.
 *
 * Por eso aquí no se «registra una venta»: se AVANZA un pedido.
 *
 *   pagado    → se crea el pedido y se RESERVA el stock. La mercancía sigue
 *               en el almacén, pero ya no la puede vender otro canal.
 *   enviado   → se sirve la reserva y entonces sale del libro.
 *   cancelado → se libera la reserva, o vuelve el stock si ya se había
 *               servido.
 *
 * Cada paso es una operación con su propio identificador derivado del pedido,
 * así que repetir un aviso no repite el paso.
 */
import { createHmac, timingSafeEqual } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import { woocommerce as config } from './integraciones';
import { operacionIdDe } from './ingesta';

/* ─────────────────────────── Forma de los datos ─────────────────────────── */

export interface LineaPedido {
  id?: number;
  name?: string;
  product_id?: number;
  variation_id?: number;
  sku?: string | null;
  quantity: number;
  price?: number | string | null;
  total?: string | null;
}

export interface Reembolso {
  id?: number;
  total?: string;
  line_items?: LineaPedido[];
}

export interface Pedido {
  id: number;
  number?: string;
  status?: string;
  currency?: string;
  total?: string;
  date_created_gmt?: string;
  date_paid_gmt?: string;
  date_modified_gmt?: string;
  payment_method_title?: string;
  line_items?: LineaPedido[];
  refunds?: Reembolso[];
  billing?: { email?: string; first_name?: string; last_name?: string; company?: string };
}

/* ─────────────────────────── Firma del webhook ───────────────────────────
   WooCommerce firma con HMAC-SHA256 sobre el cuerpo crudo, en base64, y lo
   manda en `x-wc-webhook-signature`. Esto sí está fijado por su código, no
   hay ambigüedad.
   ──────────────────────────────────────────────────────────────── */

export function firmaValida(
  cuerpoCrudo: string,
  cabeceras: Headers,
  secreto: string,
): { valida: boolean; motivo?: string } {
  if (!secreto) return { valida: true };

  const recibida = cabeceras.get('x-wc-webhook-signature');
  if (!recibida) return { valida: false, motivo: 'El envío no trae cabecera de firma.' };

  const esperada = createHmac('sha256', secreto).update(cuerpoCrudo, 'utf8').digest('base64');
  const a = Buffer.from(recibida.trim());
  const b = Buffer.from(esperada);
  if (a.length !== b.length) return { valida: false, motivo: 'La firma no coincide.' };

  return timingSafeEqual(a, b)
    ? { valida: true }
    : { valida: false, motivo: 'La firma no coincide con el secreto configurado.' };
}

/** WooCommerce comprueba la URL antes de guardar el webhook con un ping. */
export function esPing(cabeceras: Headers, payload: unknown): boolean {
  if (cabeceras.get('x-wc-webhook-topic') === null) return true;
  return !!payload && typeof payload === 'object'
      && 'webhook_id' in (payload as object)
      && !('id' in (payload as object) && 'line_items' in (payload as object));
}

/* ─────────────────────────── Estados ───────────────────────────
   Qué significa cada estado de WooCommerce para el inventario. Se puede
   ajustar sin tocar código: no todas las tiendas usan los mismos.
   ──────────────────────────────────────────────────────────────── */

function lista(variable: string, defecto: string): string[] {
  return (process.env[variable] || defecto)
    .split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
}

export const estados = {
  /** El pedido está en firme: se compromete el stock. */
  get reserva(): string[] { return lista('WOOCOMMERCE_ESTADOS_RESERVA', 'processing,on-hold'); },
  /** El pedido ha salido: el stock se descuenta de verdad. */
  get servido(): string[] { return lista('WOOCOMMERCE_ESTADOS_SERVIDO', 'completed'); },
  /** El pedido se cae: se suelta lo reservado o vuelve lo servido. */
  get cancelado(): string[] {
    return lista('WOOCOMMERCE_ESTADOS_CANCELADO', 'cancelled,failed,trash,refunded');
  },
};

export type Paso = 'reservar' | 'servir' | 'cancelar' | 'ignorar';

export function pasoPara(estado: string | undefined): Paso {
  const e = String(estado ?? '').toLowerCase();
  if (estados.cancelado.includes(e)) return 'cancelar';
  if (estados.servido.includes(e)) return 'servir';
  if (estados.reserva.includes(e)) return 'reservar';
  // `pending` es un carrito abandonado a la espera de pago: no compromete nada.
  return 'ignorar';
}

/* ─────────────────────────── Mapeo ─────────────────────────── */

export interface Mapeo { codigo_externo: string; sku: string }

export interface LineaMapeada { sku: string; cantidad: number; precio_unit?: number }

export interface ResultadoMapeo {
  lineas: LineaMapeada[];
  sinMapear: { codigo: string; nombre: string; cantidad: number }[];
}

/** Claves por las que se reconoce una línea, de más específica a menos. */
export function clavesDe(l: LineaPedido): string[] {
  return [
    l.variation_id ? String(l.variation_id) : '',
    l.product_id ? String(l.product_id) : '',
    (l.sku ?? '').trim(),
  ].filter(Boolean);
}

export function mapearLineas(lineas: LineaPedido[], mapeo: Mapeo[]): ResultadoMapeo {
  const porCodigo = new Map(mapeo.map((m) => [m.codigo_externo, m.sku]));
  const resultado: LineaMapeada[] = [];
  const sinMapear: ResultadoMapeo['sinMapear'] = [];

  for (const l of lineas) {
    const cantidad = Math.abs(Number(l.quantity ?? 0));
    if (!cantidad) continue;

    const sku = clavesDe(l).map((c) => porCodigo.get(c)).find(Boolean);
    if (!sku) {
      sinMapear.push({
        codigo: clavesDe(l)[0] ?? (l.name ?? 'sin código'),
        nombre: l.name ?? 'sin nombre',
        cantidad,
      });
      continue;
    }

    const precio = l.price === null || l.price === undefined ? undefined : Number(l.price);
    const previa = resultado.find((x) => x.sku === sku);
    if (previa) previa.cantidad += cantidad;
    else {
      resultado.push({
        sku, cantidad,
        ...(precio !== undefined && Number.isFinite(precio) ? { precio_unit: precio } : {}),
      });
    }
  }

  return { lineas: resultado, sinMapear };
}

export class ErrorMapeo extends Error {
  constructor(readonly sinMapear: ResultadoMapeo['sinMapear']) {
    super(
      `Hay ${sinMapear.length} artículo(s) sin mapear: `
      + sinMapear.map((s) => `${s.nombre} (${s.codigo})`).join(', '),
    );
    this.name = 'ErrorMapeo';
  }
}

export function momentoDe(p: Pedido): string {
  const crudo = p.date_paid_gmt ?? p.date_created_gmt ?? p.date_modified_gmt;
  // WooCommerce manda las fechas GMT sin zona: hay que ponérsela o se
  // interpretarían como hora local y la venta saldría corrida.
  const d = crudo ? new Date(/[Zz+]/.test(crudo) ? crudo : `${crudo}Z`) : new Date();
  return Number.isNaN(d.getTime()) ? new Date().toISOString() : d.toISOString();
}

export const referenciaDe = (p: Pedido): string => `woo-${p.id}`;

/* ─────────────────────────── Avance del pedido ─────────────────────────── */

export interface ResultadoProceso {
  paso: Paso;
  pedidoId?: string;
  detalle?: unknown;
}

export async function procesarPedido(
  db: SupabaseClient,
  pedido: Pedido,
  opciones: { ubicacion: string; eventoId?: string },
): Promise<ResultadoProceso> {
  const paso = pasoPara(pedido.status);
  if (paso === 'ignorar') return { paso };

  const referencia = referenciaDe(pedido);
  const cuando = momentoDe(pedido);

  const { data: mapeo, error: errorMapeo } = await db
    .from('mapeo_articulos').select('codigo_externo, sku').eq('canal', 'woocommerce');
  if (errorMapeo) throw new Error(`No se pudo leer el mapeo: ${errorMapeo.message}`);

  const { lineas, sinMapear } = mapearLineas(pedido.line_items ?? [], (mapeo ?? []) as Mapeo[]);

  // Igual que en Loyverse: media venta contabilizada es peor que una venta
  // pendiente, porque la pendiente se ve en conciliación y la media no.
  if (sinMapear.length > 0) throw new ErrorMapeo(sinMapear);
  if (lineas.length === 0) throw new Error('El pedido no trae ninguna línea con cantidad.');

  // El pedido tiene que existir antes de poder avanzarlo. Es idempotente, así
  // que da igual si este aviso es el primero que vemos o el quinto.
  const alta = await db.rpc('registrar_pedido_canal', {
    p_operacion_id: await operacionIdDe('woocommerce', `${referencia}:alta`),
    p_ubicacion_id: opciones.ubicacion,
    p_lineas: lineas,
    p_canal: 'Online',
    p_origen: 'woocommerce',
    p_origen_id: referencia,
    p_documento_fiscal: pedido.number ?? String(pedido.id),
    p_documento_fiscal_sistema: 'woocommerce',
    p_forma_pago: pedido.payment_method_title ?? null,
    p_ocurrido_en: cuando,
    p_nota: `Pedido web ${pedido.number ?? pedido.id}`,
  });
  if (alta.error) throw new Error(alta.error.message);

  const { data: estadoPedido, error: errorBusca } = await db.rpc('pedido_de_canal', {
    p_origen: 'woocommerce', p_origen_id: referencia,
  });
  if (errorBusca) throw new Error(errorBusca.message);

  const info = estadoPedido as {
    pedido_id: string; estado: string; reservas_activas: number; servidas: number;
  } | null;
  if (!info) throw new Error('El pedido no se pudo crear ni encontrar.');

  if (paso === 'reservar') {
    return { paso, pedidoId: info.pedido_id, detalle: alta.data };
  }

  if (paso === 'servir') {
    const { data, error } = await db.rpc('servir_reservas_pedido', {
      p_operacion_id: await operacionIdDe('woocommerce', `${referencia}:servido`),
      p_pedido_id: info.pedido_id,
      p_ocurrido_en: cuando,
      p_origen: 'woocommerce',
      p_origen_id: `${referencia}:servido`,
    });
    if (error) throw new Error(error.message);
    return { paso, pedidoId: info.pedido_id, detalle: data };
  }

  // Cancelar. Lo que todavía está reservado se suelta; lo que ya salió del
  // almacén vuelve, y a sus lotes originales.
  if (Number(info.servidas) > 0) {
    const { data, error } = await db.rpc('registrar_devolucion', {
      p_operacion_id: await operacionIdDe('woocommerce', `${referencia}:devuelto`),
      p_ubicacion_id: opciones.ubicacion,
      p_lineas: lineas.map((l) => ({ sku: l.sku, cantidad: l.cantidad })),
      p_venta_origen_id: `${referencia}:servido`,
      p_origen: 'woocommerce',
      p_origen_id: `${referencia}:devuelto`,
      p_ocurrido_en: cuando,
      p_nota: `Pedido web ${pedido.number ?? pedido.id} cancelado tras servirse`,
    });
    if (error) throw new Error(error.message);
    return { paso, pedidoId: info.pedido_id, detalle: data };
  }

  const { data, error } = await db.rpc('liberar_reservas_pedido', {
    p_operacion_id: await operacionIdDe('woocommerce', `${referencia}:liberado`),
    p_pedido_id: info.pedido_id,
    p_ocurrido_en: cuando,
  });
  if (error) throw new Error(error.message);
  return { paso, pedidoId: info.pedido_id, detalle: data };
}

/* ─────────────────────────── Cliente de la API ─────────────────────────── */

function cabeceras(): HeadersInit {
  const credenciales = Buffer.from(`${config.clave}:${config.secreto}`).toString('base64');
  return { Authorization: `Basic ${credenciales}`, 'Content-Type': 'application/json' };
}

async function llamar<T>(ruta: string, opciones: RequestInit = {}): Promise<T> {
  if (!config.activo) throw new Error('WooCommerce no está configurado.');

  const r = await fetch(`${config.url}/wp-json/wc/v3${ruta}`, {
    ...opciones,
    headers: { ...cabeceras(), ...(opciones.headers ?? {}) },
    signal: AbortSignal.timeout(25_000),
  });

  if (r.status === 401) {
    throw new Error('WooCommerce rechaza las credenciales. Revisa la clave y el secreto.');
  }
  if (!r.ok) {
    throw new Error(`WooCommerce respondió ${r.status}: ${(await r.text()).slice(0, 200)}`);
  }
  return (await r.json()) as T;
}

export interface ProductoPlano {
  /** Clave de mapeo: el identificador de la variación si la hay, si no el del producto. */
  codigo: string;
  nombre: string;
  sku_woo: string | null;
  tipo: 'simple' | 'variacion';
  /** Producto del que cuelga la variación. La API de stock es distinta. */
  padre: number | null;
}

export async function traerProductos(): Promise<ProductoPlano[]> {
  interface ProductoWoo {
    id: number; name: string; sku?: string; type?: string;
    variations?: number[]; status?: string;
  }
  interface VariacionWoo { id: number; sku?: string; attributes?: { option?: string }[] }

  const planos: ProductoPlano[] = [];
  for (let pagina = 1; pagina <= 10; pagina++) {
    const lote = await llamar<ProductoWoo[]>(
      `/products?per_page=100&page=${pagina}&status=publish`,
    );
    if (lote.length === 0) break;

    for (const p of lote) {
      if (p.type === 'variable' && p.variations?.length) {
        const variaciones = await llamar<VariacionWoo[]>(
          `/products/${p.id}/variations?per_page=100`,
        );
        for (const v of variaciones) {
          const opciones = (v.attributes ?? []).map((a) => a.option).filter(Boolean).join(' · ');
          planos.push({
            codigo: String(v.id),
            nombre: opciones ? `${p.name} · ${opciones}` : `${p.name} · variación ${v.id}`,
            sku_woo: v.sku ?? null,
            tipo: 'variacion',
            padre: p.id,
          });
        }
      } else {
        planos.push({
          codigo: String(p.id), nombre: p.name, sku_woo: p.sku ?? null,
          tipo: 'simple', padre: null,
        });
      }
    }
    if (lote.length < 100) break;
  }
  return planos.sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'));
}

export interface Publicacion { codigo: string; padre: number | null; cantidad: number }

/**
 * Publica el stock en la tienda.
 *
 * Es la sincronización inversa: sin ella, la web seguiría vendiendo café que
 * ya se vendió en un mercado el sábado por la mañana.
 */
export async function publicarStock(cambios: Publicacion[]): Promise<{ enviados: number }> {
  if (cambios.length === 0) return { enviados: 0 };

  const simples = cambios.filter((c) => c.padre === null);
  const porPadre = new Map<number, Publicacion[]>();
  for (const c of cambios.filter((x) => x.padre !== null)) {
    const lista = porPadre.get(c.padre!) ?? [];
    lista.push(c);
    porPadre.set(c.padre!, lista);
  }

  const cuerpo = (lista: Publicacion[]) => ({
    update: lista.map((c) => ({
      id: Number(c.codigo),
      manage_stock: true,
      stock_quantity: c.cantidad,
      stock_status: c.cantidad > 0 ? 'instock' : 'outofstock',
    })),
  });

  let enviados = 0;
  // La API acepta 100 por tanda; con 20-30 referencias sobra una.
  for (let i = 0; i < simples.length; i += 100) {
    const tanda = simples.slice(i, i + 100);
    await llamar('/products/batch', { method: 'POST', body: JSON.stringify(cuerpo(tanda)) });
    enviados += tanda.length;
  }
  for (const [padre, lista] of porPadre) {
    for (let i = 0; i < lista.length; i += 100) {
      const tanda = lista.slice(i, i + 100);
      await llamar(`/products/${padre}/variations/batch`, {
        method: 'POST', body: JSON.stringify(cuerpo(tanda)),
      });
      enviados += tanda.length;
    }
  }

  return { enviados };
}
