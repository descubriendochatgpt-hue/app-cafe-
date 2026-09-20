import { describe, it, expect, afterEach } from 'vitest';
import { createHmac } from 'node:crypto';
import {
  firmaValida, esPing, pasoPara, mapearLineas, clavesDe, momentoDe, referenciaDe,
  type LineaPedido, type Mapeo,
} from '../woocommerce';

const SECRETO = 'secreto-de-webhook-de-woocommerce';
const firmar = (c: string, s = SECRETO) =>
  createHmac('sha256', s).update(c, 'utf8').digest('base64');
const cab = (v: Record<string, string>) => new Headers(v);

afterEach(() => {
  delete process.env.WOOCOMMERCE_ESTADOS_RESERVA;
  delete process.env.WOOCOMMERCE_ESTADOS_SERVIDO;
  delete process.env.WOOCOMMERCE_ESTADOS_CANCELADO;
});

describe('firma del webhook', () => {
  const cuerpo = '{"id":5001,"status":"processing"}';

  it('acepta la firma que manda WooCommerce', () => {
    expect(firmaValida(cuerpo, cab({ 'x-wc-webhook-signature': firmar(cuerpo) }), SECRETO).valida)
      .toBe(true);
  });

  it('rechaza un cuerpo manipulado después de firmar', () => {
    const firma = firmar(cuerpo);
    const falso = cuerpo.replace('5001', '9999');
    expect(firmaValida(falso, cab({ 'x-wc-webhook-signature': firma }), SECRETO).valida).toBe(false);
  });

  it('rechaza una firma hecha con otro secreto', () => {
    expect(firmaValida(cuerpo, cab({ 'x-wc-webhook-signature': firmar(cuerpo, 'otro') }), SECRETO).valida)
      .toBe(false);
  });

  it('rechaza un envío sin firma', () => {
    const r = firmaValida(cuerpo, cab({}), SECRETO);
    expect(r.valida).toBe(false);
    expect(r.motivo).toMatch(/cabecera/);
  });

  it('no exige firma si no hay secreto configurado', () => {
    expect(firmaValida(cuerpo, cab({}), '').valida).toBe(true);
  });
});

describe('comprobación de la URL', () => {
  it('reconoce el ping que hace WooCommerce al guardar el webhook', () => {
    expect(esPing(cab({}), { webhook_id: 3 })).toBe(true);
  });

  it('no confunde un pedido con un ping', () => {
    expect(esPing(cab({ 'x-wc-webhook-topic': 'order.updated' }), {
      id: 5001, line_items: [],
    })).toBe(false);
  });
});

describe('qué significa cada estado', () => {
  it('reparte los estados de WooCommerce entre los tres pasos', () => {
    expect(pasoPara('processing')).toBe('reservar');
    expect(pasoPara('on-hold')).toBe('reservar');
    expect(pasoPara('completed')).toBe('servir');
    expect(pasoPara('cancelled')).toBe('cancelar');
    expect(pasoPara('refunded')).toBe('cancelar');
    expect(pasoPara('failed')).toBe('cancelar');
  });

  it('ignora un carrito pendiente de pago', () => {
    // `pending` es un carrito abandonado: no puede comprometer stock.
    expect(pasoPara('pending')).toBe('ignorar');
    expect(pasoPara(undefined)).toBe('ignorar');
    expect(pasoPara('inventado')).toBe('ignorar');
  });

  it('no distingue mayúsculas', () => {
    expect(pasoPara('COMPLETED')).toBe('servir');
  });

  it('se puede ajustar sin tocar código', () => {
    // Hay tiendas que envían en cuanto el pago entra, sin pasar por completed.
    process.env.WOOCOMMERCE_ESTADOS_SERVIDO = 'processing,completed';
    process.env.WOOCOMMERCE_ESTADOS_RESERVA = 'on-hold';
    expect(pasoPara('processing')).toBe('servir');
    expect(pasoPara('on-hold')).toBe('reservar');
  });
});

describe('mapeo de líneas', () => {
  const MAPEO: Mapeo[] = [
    { codigo_externo: '442', sku: 'ETHYIR-F250G' },     // variación
    { codigo_externo: '77', sku: 'COLHUI-F250G' },      // producto simple
  ];

  it('prefiere la variación al producto', () => {
    // Un producto variable tiene varias variaciones con distinto formato:
    // mapear por producto las confundiría todas en una sola referencia.
    expect(clavesDe({ variation_id: 442, product_id: 441, sku: 'X', quantity: 1 }))
      .toEqual(['442', '441', 'X']);
  });

  it('mapea variaciones y productos simples', () => {
    const r = mapearLineas([
      { variation_id: 442, product_id: 441, quantity: 2, price: 12.5 },
      { product_id: 77, quantity: 1, price: '11.00' },
    ], MAPEO);
    expect(r.sinMapear).toHaveLength(0);
    expect(r.lineas).toEqual([
      { sku: 'ETHYIR-F250G', cantidad: 2, precio_unit: 12.5 },
      { sku: 'COLHUI-F250G', cantidad: 1, precio_unit: 11 },
    ]);
  });

  it('junta líneas repetidas del mismo artículo', () => {
    const r = mapearLineas([
      { variation_id: 442, quantity: 1, price: 12.5 },
      { variation_id: 442, quantity: 2, price: 12.5 },
    ], MAPEO);
    expect(r.lineas).toHaveLength(1);
    expect(r.lineas[0]!.cantidad).toBe(3);
  });

  it('señala lo que no conoce', () => {
    const r = mapearLineas([
      { variation_id: 442, quantity: 1 },
      { product_id: 999, name: 'Taza de cerámica', quantity: 1 },
    ], MAPEO);
    expect(r.lineas).toHaveLength(1);
    expect(r.sinMapear).toEqual([{ codigo: '999', nombre: 'Taza de cerámica', cantidad: 1 }]);
  });

  it('aguanta un precio ilegible sin perder la línea', () => {
    const r = mapearLineas([{ variation_id: 442, quantity: 1, price: 'gratis' }], MAPEO);
    expect(r.lineas[0]!.sku).toBe('ETHYIR-F250G');
    expect(r.lineas[0]!.precio_unit).toBeUndefined();
  });

  it('salta las líneas sin cantidad', () => {
    const vacias: LineaPedido[] = [{ variation_id: 442, quantity: 0 }];
    expect(mapearLineas(vacias, MAPEO).lineas).toHaveLength(0);
  });
});

describe('fechas y referencias', () => {
  it('interpreta como GMT las fechas que WooCommerce manda sin zona', () => {
    // Sin esto se leerían como hora local y la venta saldría corrida dos horas.
    expect(momentoDe({ id: 1, date_paid_gmt: '2026-09-18T08:00:00' }))
      .toBe('2026-09-18T08:00:00.000Z');
  });

  it('prefiere la fecha de pago a la de creación', () => {
    expect(momentoDe({
      id: 1, date_created_gmt: '2026-09-17T20:00:00', date_paid_gmt: '2026-09-18T08:00:00',
    })).toBe('2026-09-18T08:00:00.000Z');
  });

  it('aguanta una fecha ilegible', () => {
    const d = momentoDe({ id: 1, date_paid_gmt: 'el martes' });
    expect(Number.isNaN(new Date(d).getTime())).toBe(false);
  });

  it('la referencia del pedido es estable', () => {
    expect(referenciaDe({ id: 5001 })).toBe('woo-5001');
  });
});
