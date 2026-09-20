/**
 * Preguntas al negocio, en lenguaje llano.
 *
 * El reconocimiento es determinista —palabras clave y nombres de café—, no un
 * modelo de lenguaje. Tres razones:
 *
 *   · las respuestas son hechos de la base; un modelo no los mejora, solo
 *     añade una forma nueva de equivocarse;
 *   · no cuesta nada por mensaje ni añade latencia;
 *   · se puede probar. Una respuesta mal formada se ve en un test.
 *
 * Si algún día se quiere entender preguntas más libres, esta capa es el sitio:
 * basta con traducir la frase a una de estas intenciones antes de resolverla,
 * dejando intacto lo que consulta la base.
 *
 * IMPORTANTE: quien pregunta consulta con SU perfil. Un operario no recibe
 * importes porque las políticas RLS no se los devuelven, no porque este
 * código los filtre.
 */
import type { SupabaseClient } from '@supabase/supabase-js';
import type { Rol } from './tipos';

/** Sin acentos y en minúsculas: nadie escribe «depósito» con tilde en un móvil. */
export function normalizar(t: string): string {
  return t.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
}

export type Intencion =
  | 'ayuda' | 'stock' | 'pedidos' | 'deposito' | 'frescura'
  | 'verde' | 'minimos' | 'ventas' | 'incidencias' | 'tuestes' | 'desconocida';

interface Patron { intencion: Intencion; palabras: string[] }

// El orden importa: gana el primero que encaje, así que lo específico va antes
// que lo general. «stock en depósito» es una pregunta de depósito, no de stock.
const PATRONES: Patron[] = [
  { intencion: 'ayuda',       palabras: ['ayuda', 'help', 'que puedes', 'que sabes', 'comandos', 'hola'] },
  { intencion: 'deposito',    palabras: ['deposito', 'corte ingles', 'eci'] },
  { intencion: 'frescura',    palabras: ['frescura', 'fresco', 'viejo', 'caduca', 'antiguo', 'envejec'] },
  { intencion: 'minimos',     palabras: ['minimo', 'reponer', 'falta', 'agotado', 'sin stock'] },
  { intencion: 'verde',       palabras: ['verde', 'sacos', 'saco', 'crudo'] },
  { intencion: 'pedidos',     palabras: ['pedido', 'pendiente', 'servir', 'preparar'] },
  { intencion: 'ventas',      palabras: ['venta', 'vendido', 'facturacion', 'ingresos', 'caja'] },
  { intencion: 'incidencias', palabras: ['incidencia', 'conciliacion', 'alerta', 'problema', 'error'] },
  { intencion: 'tuestes',     palabras: ['tueste', 'tostado', 'merma', 'produccion'] },
  { intencion: 'stock',       palabras: ['stock', 'existencias', 'queda', 'quedan', 'hay', 'cuanto'] },
];

export function reconocer(pregunta: string): { intencion: Intencion; resto: string } {
  const t = normalizar(pregunta);
  for (const p of PATRONES) {
    const encaja = p.palabras.find((w) => t.includes(w));
    if (encaja) return { intencion: p.intencion, resto: t.replace(encaja, '').trim() };
  }
  // Sin palabra clave, si menciona un café se entiende que pregunta por su stock.
  return { intencion: t.length > 2 ? 'stock' : 'desconocida', resto: t };
}

const AYUDA = [
  'Esto es lo que sé contestar:',
  '',
  '· stock — qué hay y dónde. Puedes añadir un café: "stock etiopía"',
  '· mínimos — qué está por debajo del mínimo',
  '· pedidos — lo que está pendiente de salir',
  '· depósito — qué hay en El Corte Inglés y si cuadra',
  '· frescura — lotes que envejecen',
  '· verde — kilos de café verde que quedan',
  '· tuestes — los últimos tuestes y su merma',
  '· ventas — resumen de los últimos siete días',
  '· incidencias — lo que necesita una decisión',
].join('\n');

const num = (v: unknown) => Number(v ?? 0);
const euros = (v: unknown) => `${num(v).toFixed(2)} €`;

/** Respuestas cortas: esto se lee en un mensaje directo, no en una pantalla. */
const TOPE = 12;

export async function responder(
  db: SupabaseClient, pregunta: string, rol: Rol,
): Promise<string> {
  const { intencion, resto } = reconocer(pregunta);

  switch (intencion) {
    case 'ayuda':
      return AYUDA;

    case 'stock': {
      const { data, error } = await db
        .from('v_stock').select('sku, cafe, formato, ubicacion, cantidad, disponible, unidad');
      if (error) return 'No he podido consultar el stock.';

      const filas = (data ?? []).filter((f) => {
        if (!resto) return num(f.cantidad) > 0;
        const busca = normalizar(`${f.cafe} ${f.formato ?? ''} ${f.sku}`);
        return num(f.cantidad) > 0 && resto.split(/\s+/).every((p) => busca.includes(p));
      });

      if (filas.length === 0) {
        return resto
          ? `No encuentro nada con "${resto}". Prueba con el nombre del café.`
          : 'No hay existencias de nada ahora mismo.';
      }

      // Se agrupa por artículo, con el desglose por sitio debajo.
      const porSku = new Map<string, { cafe: string; formato: string; unidad: string;
                                        total: number; sitios: string[] }>();
      for (const f of filas) {
        const g = porSku.get(f.sku as string) ?? {
          cafe: f.cafe as string, formato: (f.formato as string) ?? '',
          unidad: f.unidad as string, total: 0, sitios: [],
        };
        g.total += num(f.cantidad);
        g.sitios.push(`${f.ubicacion}: ${num(f.cantidad)}`);
        porSku.set(f.sku as string, g);
      }

      const lineas = [...porSku.values()].slice(0, TOPE).map((g) =>
        `${g.cafe}${g.formato ? ` ${g.formato}` : ''}: ${g.total}${g.unidad === 'KG' ? ' kg' : ''}`
        + `\n   ${g.sitios.join(' · ')}`);

      return [`Stock${resto ? ` de "${resto}"` : ''}:`, '', ...lineas,
              porSku.size > TOPE ? `\n…y ${porSku.size - TOPE} más.` : ''].join('\n').trim();
    }

    case 'minimos': {
      const [stock, precios] = await Promise.all([
        db.from('v_stock').select('sku, cafe, formato, cantidad'),
        db.from('precios').select('sku, stock_minimo'),
      ]);
      if (stock.error) return 'No he podido consultar el stock.';
      if ((precios.data ?? []).length === 0) {
        return rol === 'OPERARIO'
          ? 'Los mínimos van con los precios, y tu perfil no los incluye.'
          : 'No hay mínimos puestos todavía. Se ponen en Ajustes → Catálogo → Precios.';
      }

      const minimos = new Map((precios.data ?? [])
        .filter((p) => p.stock_minimo !== null)
        .map((p) => [p.sku, num(p.stock_minimo)]));

      const total = new Map<string, { nombre: string; hay: number }>();
      for (const f of stock.data ?? []) {
        const g = total.get(f.sku as string)
          ?? { nombre: `${f.cafe}${f.formato ? ` ${f.formato}` : ''}`, hay: 0 };
        g.hay += num(f.cantidad);
        total.set(f.sku as string, g);
      }

      const bajos = [...minimos.entries()]
        .map(([sku, min]) => ({ sku, min, ...(total.get(sku) ?? { nombre: sku, hay: 0 }) }))
        .filter((x) => x.hay <= x.min)
        .sort((a, b) => (a.hay - a.min) - (b.hay - b.min));

      if (bajos.length === 0) return 'Nada por debajo del mínimo. Todo en orden.';
      return ['Por debajo del mínimo:', '',
        ...bajos.slice(0, TOPE).map((x) => `${x.nombre}: ${x.hay} (mínimo ${x.min})`)].join('\n');
    }

    case 'pedidos': {
      const { data, error } = await db
        .from('pedidos_operativo').select('numero, canal, fecha, cliente_id, estado')
        .in('estado', ['CONFIRMADO', 'PREPARANDO']).order('fecha');
      if (error) return 'No he podido consultar los pedidos.';
      if ((data ?? []).length === 0) return 'No hay pedidos pendientes de salir.';

      const { data: clientes } = await db.from('clientes').select('cliente_id, nombre');
      const nombres = new Map((clientes ?? []).map((c) => [c.cliente_id, c.nombre]));

      return [`${data!.length} pedido(s) pendiente(s):`, '',
        ...data!.slice(0, TOPE).map((p) =>
          `${p.numero} · ${nombres.get(p.cliente_id as string) ?? 'sin cliente'} (${p.canal})`)].join('\n');
    }

    case 'deposito': {
      const { data, error } = await db.from('v_deposito').select('*');
      if (error) return 'No he podido consultar el depósito.';
      if ((data ?? []).length === 0) return 'No hay nada en depósito ahora mismo.';

      const descuadres = (data ?? []).filter((d) => num(d.descuadre) !== 0);
      const viejos = (data ?? []).filter((d) => d.envejecido);

      return [
        'En depósito:', '',
        ...data!.slice(0, TOPE).map((d) =>
          `${d.sku}: ${num(d.saldo)} (servido ${num(d.servido)}, vendido ${num(d.vendido)},`
          + ` devuelto ${num(d.devuelto)})`
          + (d.dias_en_deposito ? ` · ${d.dias_en_deposito} días` : '')),
        '',
        descuadres.length > 0
          ? `⚠ ${descuadres.length} lote(s) no cuadran. Míralo en Conciliación.`
          : 'Todo cuadra.',
        viejos.length > 0 ? `${viejos.length} lote(s) llevan demasiado tiempo allí.` : '',
      ].filter(Boolean).join('\n');
    }

    case 'frescura': {
      const { data, error } = await db
        .from('v_frescura').select('sku, ubicacion_id, cantidad, dias_desde_tueste, frescura')
        .neq('frescura', 'FRESCO').order('dias_desde_tueste', { ascending: false });
      if (error) return 'No he podido consultar la frescura.';
      if ((data ?? []).length === 0) return 'Todo lo que hay está fresco.';

      return ['Lotes que envejecen:', '',
        ...data!.slice(0, TOPE).map((f) =>
          `${f.sku} en ${f.ubicacion_id}: ${num(f.cantidad)} uds, ${f.dias_desde_tueste} días`
          + `${f.frescura === 'CRITICO' ? ' ⚠' : ''}`)].join('\n');
    }

    case 'verde': {
      const { data, error } = await db
        .from('v_stock').select('cafe, cantidad, unidad, ubicacion').eq('unidad', 'KG');
      if (error) return 'No he podido consultar el café verde.';
      const filas = (data ?? []).filter((f) => num(f.cantidad) > 0);
      if (filas.length === 0) return 'No queda café verde en el almacén.';

      return ['Café verde:', '',
        ...filas.slice(0, TOPE).map((f) => `${f.cafe}: ${num(f.cantidad)} kg (${f.ubicacion})`)]
        .join('\n');
    }

    case 'tuestes': {
      const { data, error } = await db
        .from('operaciones').select('ocurrido_en, datos')
        .eq('tipo', 'TUESTE').order('ocurrido_en', { ascending: false }).limit(TOPE);
      if (error) return 'No he podido consultar los tuestes.';
      if ((data ?? []).length === 0) return 'No hay tuestes registrados todavía.';

      return ['Últimos tuestes:', '', ...data!.map((o) => {
        const d = o.datos as { kg_verde?: number; kg_tostado?: number; merma_pct?: number };
        const cuando = new Date(o.ocurrido_en as string).toLocaleDateString('es-ES');
        return `${cuando}: ${d.kg_verde ?? '?'} kg → ${d.kg_tostado ?? '?'} kg`
             + (d.merma_pct !== undefined ? ` (merma ${d.merma_pct}%)` : '');
      })].join('\n');
    }

    case 'ventas': {
      const desde = new Date(Date.now() - 7 * 86_400_000).toISOString().slice(0, 10);
      const { data, error } = await db
        .from('pedidos').select('canal, total, fecha').gte('fecha', desde);

      if (error || data === null) {
        return rol === 'OPERARIO'
          ? 'Tu perfil no incluye importes, así que no puedo darte las ventas.'
          : 'No he podido consultar las ventas.';
      }
      if (data.length === 0) return 'No hay ventas registradas en los últimos siete días.';

      const porCanal = new Map<string, { n: number; total: number }>();
      for (const p of data) {
        const g = porCanal.get(p.canal as string) ?? { n: 0, total: 0 };
        g.n++; g.total += num(p.total);
        porCanal.set(p.canal as string, g);
      }
      const total = [...porCanal.values()].reduce((s, g) => s + g.total, 0);

      return ['Últimos 7 días:', '',
        ...[...porCanal.entries()].map(([canal, g]) => `${canal}: ${g.n} · ${euros(g.total)}`),
        '', `Total: ${euros(total)}`].join('\n');
    }

    case 'incidencias': {
      const { data, error } = await db
        .from('incidencias').select('tipo, canal, referencia, creado_en')
        .eq('estado', 'ABIERTA').order('creado_en', { ascending: false });
      if (error) return 'No he podido consultar las incidencias.';
      if ((data ?? []).length === 0) return 'No hay nada pendiente de resolver. Todo va solo.';

      return [`${data!.length} incidencia(s) abierta(s):`, '',
        ...data!.slice(0, TOPE).map((i) =>
          `${String(i.tipo).replaceAll('_', ' ').toLowerCase()}`
          + `${i.referencia ? ` · ${i.referencia}` : ''}`)].join('\n');
    }

    default:
      return `No he entendido la pregunta.\n\n${AYUDA}`;
  }
}
