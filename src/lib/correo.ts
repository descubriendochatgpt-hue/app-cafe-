/**
 * El aviso diario por correo.
 *
 * Es la única pieza que sale a buscar a la persona. Dos consecuencias:
 *
 *  · El correo tiene que entenderse SOLO. Nada de «3 avisos, entra a verlos»:
 *    van los nombres dentro, para poder decidir desde el propio correo.
 *
 *  · El HTML de un correo no es el de una web. Ni variables CSS, ni flexbox
 *    fiable, ni hojas de estilo: Outlook y Gmail recortan casi todo. Por eso
 *    esto se escribe con tablas y estilos en línea, que es feo de leer y es
 *    lo único que se ve igual en todas partes. Y por eso va siempre con una
 *    versión en texto plano: hay quien lee el correo así, y los filtros de
 *    spam desconfían de lo que solo viene en HTML.
 */
import { z } from 'zod';

const v = (nombre: string): string => (process.env[nombre] ?? '').trim();

export const avisos = {
  get activo(): boolean { return v('RESEND_API_KEY') !== '' && this.para.length > 0; },
  get clave(): string { return v('RESEND_API_KEY'); },
  get de(): string { return v('AVISOS_DE') || 'avisos@localhost'; },
  get para(): string[] {
    return v('AVISOS_PARA').split(/[,;\s]+/).filter((d) => d.includes('@'));
  },
};

/* ── Lo que devuelve resumen_diario() ── */

export const resumenSchema = z.object({
  fecha: z.string(),
  ventas: z.object({
    pedidos: z.coerce.number(), total: z.coerce.number(), unidades: z.coerce.number(),
  }),
  canales: z.array(z.object({
    canal: z.string(), pedidos: z.coerce.number(), total: z.coerce.number(),
  })),
  produccion: z.object({
    tuestes: z.coerce.number(), kg_verde: z.coerce.number(), kg_tostado: z.coerce.number(),
  }),
  minimos: z.array(z.object({
    sku: z.string(), quedan: z.coerce.number(), minimo: z.coerce.number(),
  })),
  frescura: z.array(z.object({
    lote: z.string(), sku: z.string(), ubicacion: z.string(),
    cantidad: z.coerce.number(), dias: z.coerce.number(), estado: z.string(),
  })),
  incidencias: z.array(z.object({
    tipo: z.string(), canal: z.string().nullable(),
    referencia: z.string().nullable(), desde: z.string(),
  })),
  pendientes: z.array(z.object({
    pedido: z.string(), canal: z.string(), cliente: z.string(),
    estado: z.string(), desde: z.string(),
  })),
  deposito: z.array(z.object({
    ubicacion: z.string(), sku: z.string(),
    saldo: z.coerce.number(), dias: z.coerce.number().nullable(),
  })),
  descuadres: z.coerce.number(),
  solo_si_hay: z.boolean(),
  hay_avisos: z.boolean(),
}).passthrough();

export type Resumen = z.infer<typeof resumenSchema>;

const euros = new Intl.NumberFormat('es-ES', { style: 'currency', currency: 'EUR' });
const kg = new Intl.NumberFormat('es-ES', { maximumFractionDigits: 1 });

const TIPOS: Record<string, string> = {
  SKU_DESCONOCIDO: 'Artículo sin mapear',
  STOCK_INSUFICIENTE: 'Se vendió sin stock',
  LOTE_SIN_RESOLVER: 'Venta sin lote claro',
  EVENTO_FALLIDO: 'Evento que no entró',
  DESCUADRE_SALDO: 'Descuadre de saldo',
  DEPOSITO_PENDIENTE: 'Depósito sin conciliar',
};

function dia(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('es-ES',
    { day: 'numeric', month: 'long', timeZone: 'UTC' });
}

/** Corta, para las líneas de detalle: en un móvil «20 sept» cabe y «20 de
    septiembre» parte la línea en dos. */
function diaCorto(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('es-ES',
    { day: 'numeric', month: 'short', timeZone: 'UTC' });
}

/** Escapar SIEMPRE: aquí entran nombres de cliente y referencias de fuera. */
function esc(t: unknown): string {
  return String(t ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** Cada bloque de avisos: un título, y las filas con nombre y detalle. */
interface Bloque { titulo: string; filas: [string, string][]; grave: boolean }

function bloques(r: Resumen): Bloque[] {
  const b: Bloque[] = [];

  // El descuadre va primero porque es el único que dice que el sistema
  // podría estar equivocado. Todo lo demás son cosas del negocio.
  if (r.descuadres > 0) {
    b.push({
      titulo: 'El libro y el stock no cuadran',
      grave: true,
      filas: [[`${r.descuadres} saldo(s) descuadrado(s)`,
               'Avisa antes de tocar nada: es un fallo del sistema, no del almacén']],
    });
  }

  if (r.incidencias.length > 0) {
    b.push({
      titulo: 'Incidencias sin resolver',
      grave: true,
      filas: r.incidencias.map((i) => [
        TIPOS[i.tipo] ?? i.tipo,
        [i.canal, i.referencia, `desde el ${diaCorto(i.desde)}`].filter(Boolean).join(' · '),
      ]),
    });
  }

  if (r.minimos.length > 0) {
    b.push({
      titulo: 'Bajo mínimos',
      grave: false,
      filas: r.minimos.map((m) => [m.sku, `quedan ${m.quedan} (mínimo ${m.minimo})`]),
    });
  }

  if (r.frescura.length > 0) {
    b.push({
      titulo: 'Café que se está pasando',
      grave: false,
      filas: r.frescura.map((f) => [
        `${f.sku} · ${f.ubicacion}`,
        `${f.cantidad} uds, ${f.dias} días desde el tueste`,
      ]),
    });
  }

  if (r.deposito.length > 0) {
    b.push({
      titulo: 'Lleva demasiado en depósito',
      grave: false,
      filas: r.deposito.map((d) => [
        `${d.sku} · ${d.ubicacion}`,
        `${d.saldo} uds${d.dias === null ? '' : `, ${d.dias} días allí`}`,
      ]),
    });
  }

  if (r.pendientes.length > 0) {
    b.push({
      titulo: 'Pedidos por preparar',
      grave: false,
      filas: r.pendientes.map((p) => [
        `${p.pedido} · ${p.cliente}`,
        `${p.canal}, del ${diaCorto(p.desde)}`,
      ]),
    });
  }

  return b;
}

export interface Correo { asunto: string; html: string; texto: string }

export function redactar(r: Resumen, base?: string): Correo {
  const bs = bloques(r);
  const cuantos = bs.reduce((n, x) => n + x.filas.length, 0);

  // El asunto es lo único que se lee seguro. Lleva las dos cifras que
  // deciden si merece la pena abrirlo.
  const ventas = r.ventas.pedidos === 0
    ? 'sin ventas'
    : `${r.ventas.pedidos} pedido${r.ventas.pedidos === 1 ? '' : 's'}, ${euros.format(r.ventas.total)}`;
  const asunto = `Café · ${dia(r.fecha)} · ${ventas}`
    + (cuantos === 0 ? ' · todo en orden' : ` · ${cuantos} por mirar`);

  /* ── Texto plano ── */
  const t: string[] = [`Resumen del ${dia(r.fecha)}`, ''];
  t.push(`Ventas: ${ventas}`);
  if (r.ventas.unidades > 0) t.push(`Unidades servidas: ${r.ventas.unidades}`);
  for (const c of r.canales) t.push(`  · ${c.canal}: ${c.pedidos} — ${euros.format(c.total)}`);
  if (r.produccion.tuestes > 0) {
    t.push(`Tuestes: ${r.produccion.tuestes} — ${kg.format(r.produccion.kg_verde)} kg verde `
         + `→ ${kg.format(r.produccion.kg_tostado)} kg tostado`);
  }
  for (const b of bs) {
    t.push('', b.titulo.toUpperCase());
    for (const [que, detalle] of b.filas) t.push(`  · ${que} — ${detalle}`);
  }
  if (cuantos === 0) t.push('', 'Nada que mirar hoy.');
  if (base) t.push('', `El panel: ${base}/panel`);

  /* ── HTML ── */
  const fila = ([que, detalle]: [string, string]) => `
      <tr>
        <td style="padding:6px 0;border-bottom:1px solid #eeeae4;font-size:14px;color:#1d2420">
          ${esc(que)}
        </td>
        <td style="padding:6px 0;border-bottom:1px solid #eeeae4;font-size:14px;color:#6b7671;text-align:right">
          ${esc(detalle)}
        </td>
      </tr>`;

  const bloque = (b: Bloque) => `
    <h2 style="margin:22px 0 6px;font-size:15px;color:${b.grave ? '#b3452f' : '#1d2420'}">
      ${esc(b.titulo)}
    </h2>
    <table width="100%" cellpadding="0" cellspacing="0" role="presentation">
      ${b.filas.map(fila).join('')}
    </table>`;

  const html = `<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(asunto)}</title></head>
<body style="margin:0;padding:0;background:#faf9f7">
  <table width="100%" cellpadding="0" cellspacing="0" role="presentation" style="background:#faf9f7">
    <tr><td align="center" style="padding:20px 12px">
      <table width="100%" cellpadding="0" cellspacing="0" role="presentation"
             style="max-width:600px;background:#ffffff;border:1px solid #e2ded7;border-radius:10px;
                    padding:22px;font-family:-apple-system,'Segoe UI',system-ui,sans-serif">
        <tr><td>
          <p style="margin:0;font-size:13px;color:#6b7671">Resumen del</p>
          <h1 style="margin:2px 0 18px;font-size:20px;color:#35543D">${esc(dia(r.fecha))}</h1>

          <table width="100%" cellpadding="0" cellspacing="0" role="presentation">
            <tr>
              <td style="font-size:26px;font-weight:700;color:#1d2420">
                ${esc(euros.format(r.ventas.total))}
              </td>
              <td style="text-align:right;font-size:14px;color:#6b7671">
                ${esc(`${r.ventas.pedidos} pedido${r.ventas.pedidos === 1 ? '' : 's'}`)}<br>
                ${esc(`${r.ventas.unidades} uds`)}
              </td>
            </tr>
          </table>

          ${r.canales.length === 0 ? '' : `
          <table width="100%" cellpadding="0" cellspacing="0" role="presentation" style="margin-top:12px">
            ${r.canales.map((c) => fila([c.canal, `${c.pedidos} — ${euros.format(c.total)}`])).join('')}
          </table>`}

          ${r.produccion.tuestes === 0 ? '' : `
          <p style="margin:14px 0 0;font-size:14px;color:#6b7671">
            ${esc(`${r.produccion.tuestes} tueste(s): ${kg.format(r.produccion.kg_verde)} kg verde `
                + `→ ${kg.format(r.produccion.kg_tostado)} kg tostado`)}
          </p>`}

          ${bs.map(bloque).join('')}

          ${cuantos > 0 ? '' : `
          <p style="margin:22px 0 0;padding:10px 12px;background:#eaf5ee;border-radius:8px;
                    font-size:14px;color:#2e7d4f">
            Nada que mirar hoy.
          </p>`}

          ${!base ? '' : `
          <p style="margin:24px 0 0">
            <a href="${esc(base)}/panel"
               style="display:inline-block;padding:10px 16px;background:#35543D;color:#ffffff;
                      border-radius:8px;text-decoration:none;font-size:14px">Abrir el panel</a>
          </p>`}

          <p style="margin:22px 0 0;font-size:12px;color:#9aa8a1;border-top:1px solid #eeeae4;padding-top:12px">
            Lo manda la aplicación del obrador, una vez al día. Las cifras salen del libro de
            movimientos: si algo no cuadra aquí, tampoco cuadra en el almacén.
          </p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;

  return { asunto, html, texto: t.join('\n') };
}

/**
 * Envío por Resend. Un solo proveedor a propósito: una capa de abstracción
 * sobre «mandar un correo al día» sería más código que el propio envío.
 */
export async function enviar(correo: Correo, para: string[]): Promise<void> {
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${avisos.clave}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      from: avisos.de, to: para,
      subject: correo.asunto, html: correo.html, text: correo.texto,
    }),
  });

  if (!r.ok) {
    throw new Error(`Resend respondió ${r.status}: ${(await r.text()).slice(0, 300)}`);
  }
}
