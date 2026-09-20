/**
 * Sincronización inversa: publicar el stock en la tienda.
 *
 * Sin esto, la web seguiría vendiendo el café que se vendió el sábado en un
 * mercado. Se publica lo DISPONIBLE (existencias menos lo ya comprometido por
 * otros pedidos) en la ubicación dedicada a la web, menos el colchón que se
 * quiera dejar.
 *
 * Solo se envían las referencias cuyo número ha cambiado desde la última vez.
 * No es por rendimiento —con 20-30 referencias da igual—, sino para no llenar
 * el registro de cambios de la tienda con ruido que oculte los cambios reales.
 */
import { NextResponse } from 'next/server';
import { comoSistema } from '@/lib/sistema';
import { woocommerce as config } from '@/lib/integraciones';
import { publicarStock, type Publicacion } from '@/lib/woocommerce';
import { autorizada } from '@/lib/cron';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

interface FilaMapeo {
  codigo_externo: string;
  sku: string;
  datos: { tipo?: string; padre?: number | null } | null;
}

export async function GET(peticion: Request) {
  if (!autorizada(peticion)) {
    return NextResponse.json({ error: 'No autorizada.' }, { status: 401 });
  }
  if (!config.activo) {
    return NextResponse.json({ ok: true, nota: 'WooCommerce no está configurado.' });
  }

  const db = await comoSistema();

  const [mapeo, saldos, publicado] = await Promise.all([
    db.from('mapeo_articulos').select('codigo_externo, sku, datos').eq('canal', 'woocommerce'),
    db.from('v_saldo_detalle').select('sku, disponible').eq('ubicacion_id', config.ubicacion),
    db.from('stock_publicado').select('sku, cantidad').eq('canal', 'woocommerce'),
  ]);

  const fallo = [mapeo, saldos, publicado].find((r) => r.error);
  if (fallo?.error) {
    return NextResponse.json({ error: fallo.error.message }, { status: 500 });
  }

  // Disponible por artículo, sumando sus lotes.
  const disponible = new Map<string, number>();
  for (const s of saldos.data ?? []) {
    disponible.set(s.sku, (disponible.get(s.sku) ?? 0) + Number(s.disponible));
  }

  const yaPublicado = new Map((publicado.data ?? []).map((p) => [p.sku, Number(p.cantidad)]));

  const cambios: Publicacion[] = [];
  const nuevos: { sku: string; cantidad: number }[] = [];

  for (const m of (mapeo.data ?? []) as FilaMapeo[]) {
    const bruto = disponible.get(m.sku) ?? 0;
    // El colchón evita quedarse vendido por el desfase entre que alguien
    // compra en la web y el pedido llega aquí.
    const publicable = Math.max(0, Math.floor(bruto - config.colchon));

    if (yaPublicado.get(m.sku) === publicable) continue;

    cambios.push({
      codigo: m.codigo_externo,
      padre: m.datos?.padre ?? null,
      cantidad: publicable,
    });
    nuevos.push({ sku: m.sku, cantidad: publicable });
  }

  if (cambios.length === 0) {
    return NextResponse.json({ ok: true, cambios: 0, nota: 'El stock publicado ya estaba al día.' });
  }

  try {
    const { enviados } = await publicarStock(cambios);

    // La marca de lo publicado solo se actualiza si la tienda lo aceptó. Si
    // falló, la próxima vuelta lo reintenta en vez de darlo por hecho.
    const { error } = await db.from('stock_publicado').upsert(
      nuevos.map((n) => ({ canal: 'woocommerce', ...n, publicado_en: new Date().toISOString() })),
      { onConflict: 'canal,sku' },
    );
    if (error) throw new Error(`Publicado en la tienda pero no anotado: ${error.message}`);

    return NextResponse.json({ ok: true, cambios: enviados, detalle: nuevos });
  } catch (e) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : 'No se pudo publicar el stock.', intentados: cambios.length },
      { status: 502 },
    );
  }
}
