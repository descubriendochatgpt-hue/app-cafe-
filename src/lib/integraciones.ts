/**
 * Integraciones: única fuente de verdad sobre qué canales están conectados.
 *
 * Todo sale de `integraciones.ejemplo.env` (copiado a `.env.local`). Aquí no
 * se decide nada: se lee, se valida y se informa. Un canal sin claves no
 * rompe la app — queda «sin configurar» y su webhook responde que no está
 * activo, en vez de fallar de una forma que haya que investigar.
 *
 * Añadir claves ENCIENDE el canal sin tocar código. Es el contrato que se
 * prometió: pegar y funcionar.
 */
import { z } from 'zod';

export type EstadoIntegracion = 'lista' | 'incompleta' | 'sin_configurar';

export interface Ranura {
  /** Nombre de la variable en el fichero de integraciones. */
  variable: string;
  /** Si falta, el canal no puede funcionar. */
  obligatoria: boolean;
  /** Qué es y dónde se saca. */
  ayuda: string;
  rellena: boolean;
}

export interface Integracion {
  id: 'supabase' | 'loyverse' | 'woocommerce' | 'eci' | 'whatsapp';
  nombre: string;
  descripcion: string;
  estado: EstadoIntegracion;
  ranuras: Ranura[];
  /** Lo que hay que pegar en el panel del proveedor. */
  webhooks: { evento: string; url: string; nota?: string }[];
  /** Lo que falta para que quede lista, en una frase. */
  siguientePaso: string;
}

const v = (nombre: string): string => (process.env[nombre] ?? '').trim();
const hay = (nombre: string): boolean => v(nombre).length > 0;

/** Base pública, sin barra final, para construir las URL de webhook. */
export function baseUrl(): string {
  const dada = v('NEXT_PUBLIC_APP_URL');
  if (dada) return dada.replace(/\/+$/, '');
  if (process.env.VERCEL_URL) return `https://${process.env.VERCEL_URL}`;
  return 'http://localhost:3000';
}

function estadoDe(ranuras: Ranura[]): EstadoIntegracion {
  const obligatorias = ranuras.filter((r) => r.obligatoria);
  const puestas = obligatorias.filter((r) => r.rellena).length;
  if (puestas === 0) return 'sin_configurar';
  return puestas === obligatorias.length ? 'lista' : 'incompleta';
}

function ranura(variable: string, obligatoria: boolean, ayuda: string): Ranura {
  return { variable, obligatoria, ayuda, rellena: hay(variable) };
}

function describir(ranuras: Ranura[], estado: EstadoIntegracion, listo: string): string {
  if (estado === 'lista') return listo;
  const faltan = ranuras.filter((r) => r.obligatoria && !r.rellena).map((r) => r.variable);
  return `Falta rellenar ${faltan.join(', ')} en .env.local`;
}

/* ── Configuración tipada de cada canal ── */

const ubicacionValida = z.string().regex(/^[A-Z0-9_]{2,24}$/);

export const loyverse = {
  get activo(): boolean { return hay('LOYVERSE_ACCESS_TOKEN'); },
  get token(): string { return v('LOYVERSE_ACCESS_TOKEN'); },
  get secretoWebhook(): string { return v('LOYVERSE_WEBHOOK_SECRET'); },
  /** Sin secreto de webhook no hay tiempo real: se cae a consulta periódica. */
  get soloPolling(): boolean { return this.activo && !hay('LOYVERSE_WEBHOOK_SECRET'); },
  get ubicacion(): string {
    return ubicacionValida.catch('TIENDA').parse(v('LOYVERSE_UBICACION') || 'TIENDA');
  },
};

export const woocommerce = {
  get activo(): boolean {
    return hay('WOOCOMMERCE_URL') && hay('WOOCOMMERCE_CONSUMER_KEY')
        && hay('WOOCOMMERCE_CONSUMER_SECRET');
  },
  get url(): string { return v('WOOCOMMERCE_URL').replace(/\/+$/, ''); },
  get clave(): string { return v('WOOCOMMERCE_CONSUMER_KEY'); },
  get secreto(): string { return v('WOOCOMMERCE_CONSUMER_SECRET'); },
  get secretoWebhook(): string { return v('WOOCOMMERCE_WEBHOOK_SECRET'); },
  get ubicacion(): string {
    return ubicacionValida.catch('ONLINE').parse(v('WOOCOMMERCE_UBICACION') || 'ONLINE');
  },
  get colchon(): number {
    return z.coerce.number().int().nonnegative().catch(0).parse(v('WOOCOMMERCE_COLCHON') || '0');
  },
};

/* ── Inventario de integraciones, para la pantalla de ajustes ── */

export function inventario(): Integracion[] {
  const base = baseUrl();

  const supabase = [
    ranura('NEXT_PUBLIC_SUPABASE_URL', true, 'Project Settings → API → Project URL'),
    ranura('SUPABASE_ANON_KEY', true, 'Project Settings → API → anon public'),
    ranura('SUPABASE_SERVICE_ROLE_KEY', true, 'Project Settings → API → service_role secret'),
    ranura('SUPABASE_JWT_SECRET', true, 'Project Settings → API → JWT Settings → JWT Secret'),
  ];

  const lv = [
    ranura('LOYVERSE_ACCESS_TOKEN', true,
      'Loyverse → Integraciones → Access tokens. Permisos: RECEIPTS e ITEMS (lectura)'),
    ranura('LOYVERSE_WEBHOOK_SECRET', false,
      'Secreto que muestra Loyverse al crear el webhook. Sin él, funciona por consulta cada 5 min'),
    ranura('LOYVERSE_UBICACION', false, 'Ubicación a la que se imputan sus ventas'),
  ];

  const wc = [
    ranura('WOOCOMMERCE_URL', true, 'Dirección de la tienda, sin barra final'),
    ranura('WOOCOMMERCE_CONSUMER_KEY', true,
      'Ajustes → Avanzado → API REST → Añadir clave (Lectura/Escritura)'),
    ranura('WOOCOMMERCE_CONSUMER_SECRET', true, 'Se muestra junto a la clave anterior'),
    ranura('WOOCOMMERCE_WEBHOOK_SECRET', false,
      'El mismo valor que pongas en el campo «Secreto» de cada webhook'),
    ranura('WOOCOMMERCE_UBICACION', false, 'Ubicación cuyo stock se publica en la web'),
  ];

  const estadoLv = estadoDe(lv);
  const estadoWc = estadoDe(wc);

  return [
    {
      id: 'supabase',
      nombre: 'Supabase',
      descripcion: 'Base de datos. Sin esto no arranca nada.',
      estado: estadoDe(supabase),
      ranuras: supabase,
      webhooks: [],
      siguientePaso: describir(supabase, estadoDe(supabase), 'Conectada.'),
    },
    {
      id: 'loyverse',
      nombre: 'Loyverse',
      descripcion: 'Tienda física y mercados. Cada venta descuenta stock sola.',
      estado: estadoLv,
      ranuras: lv,
      webhooks: [{
        evento: 'receipts.update',
        url: `${base}/api/webhooks/loyverse`,
        nota: 'Loyverse → Integraciones → Webhooks → Add webhook',
      }],
      siguientePaso: estadoLv !== 'lista'
        ? describir(lv, estadoLv, '')
        : loyverse.soloPolling
          ? 'Conectada, pero sin webhook: las ventas entran por consulta cada 5 minutos. '
            + 'Rellena LOYVERSE_WEBHOOK_SECRET para tenerlas al instante.'
          : 'Conectada y en tiempo real.',
    },
    {
      id: 'woocommerce',
      nombre: 'WooCommerce',
      descripcion: 'Web y tiendas online, con publicación de stock de vuelta.',
      estado: estadoWc,
      ranuras: wc,
      webhooks: [
        { evento: 'order.created', url: `${base}/api/webhooks/woocommerce` },
        { evento: 'order.updated', url: `${base}/api/webhooks/woocommerce` },
        { evento: 'order.deleted', url: `${base}/api/webhooks/woocommerce` },
      ],
      siguientePaso: describir(wc, estadoWc,
        'Conectada. Crea los tres webhooks con la URL de arriba.'),
    },
    {
      id: 'eci',
      nombre: 'El Corte Inglés',
      descripcion: 'Depósito. En esta fase se lleva a mano, sin claves.',
      estado: 'lista',
      ranuras: [],
      webhooks: [],
      siguientePaso: 'Manual: traslados para servir y devolver, y carga del informe mensual.',
    },
    {
      id: 'whatsapp',
      nombre: 'Hostelería por WhatsApp',
      descripcion: 'Fase 5. Con la opción recomendada no hacen falta claves.',
      estado: 'sin_configurar',
      ranuras: [],
      webhooks: [],
      siguientePaso: 'Pendiente de fase.',
    },
  ];
}
