import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { createHmac } from 'node:crypto';
import {
  firmaValida, extraerRecibos, mapearRecibo, clavesDe, momentoDe, formaPagoDe,
  type Recibo, type Mapeo,
} from '../loyverse';

const SECRETO = 'secreto-de-webhook-de-pruebas';

function firmar(cuerpo: string, secreto = SECRETO, codificacion: 'hex' | 'base64' = 'hex') {
  return createHmac('sha256', secreto).update(cuerpo, 'utf8').digest(codificacion);
}

const cabeceras = (v: Record<string, string>) => new Headers(v);

describe('firma del webhook', () => {
  const cuerpo = '{"receipts":[{"receipt_number":"1-1049"}]}';

  it('acepta una firma correcta en hexadecimal', () => {
    const r = firmaValida(cuerpo, cabeceras({ 'x-loyverse-signature': firmar(cuerpo) }), SECRETO);
    expect(r.valida).toBe(true);
  });

  it('acepta una firma correcta en base64', () => {
    const r = firmaValida(
      cuerpo, cabeceras({ 'x-loyverse-signature': firmar(cuerpo, SECRETO, 'base64') }), SECRETO,
    );
    expect(r.valida).toBe(true);
  });

  it('acepta el prefijo del algoritmo', () => {
    const r = firmaValida(
      cuerpo, cabeceras({ 'x-hub-signature-256': `sha256=${firmar(cuerpo)}` }), SECRETO,
    );
    expect(r.valida).toBe(true);
  });

  it('rechaza una firma hecha con otro secreto', () => {
    const r = firmaValida(cuerpo, cabeceras({ 'x-loyverse-signature': firmar(cuerpo, 'otro') }), SECRETO);
    expect(r.valida).toBe(false);
  });

  it('rechaza un cuerpo manipulado después de firmar', () => {
    // El ataque real: te cuelan una venta inventada con la firma de otra.
    const firma = firmar(cuerpo);
    const manipulado = cuerpo.replace('1-1049', '9-9999');
    expect(firmaValida(manipulado, cabeceras({ 'x-loyverse-signature': firma }), SECRETO).valida)
      .toBe(false);
  });

  it('rechaza un envío sin cabecera de firma', () => {
    const r = firmaValida(cuerpo, cabeceras({}), SECRETO);
    expect(r.valida).toBe(false);
    expect(r.motivo).toMatch(/cabecera/);
  });

  it('no exige firma si no hay secreto configurado', () => {
    // Plan de Loyverse sin webhooks: se trabaja por consulta periódica y el
    // endpoint no puede exigir algo que nadie va a mandar.
    expect(firmaValida(cuerpo, cabeceras({}), '').valida).toBe(true);
  });

  describe('con cabecera fijada a mano', () => {
    beforeEach(() => { process.env.LOYVERSE_WEBHOOK_HEADER = 'x-mi-firma'; });
    afterEach(() => { delete process.env.LOYVERSE_WEBHOOK_HEADER; });

    it('solo mira esa cabecera', () => {
      expect(firmaValida(cuerpo, cabeceras({ 'x-mi-firma': firmar(cuerpo) }), SECRETO).valida).toBe(true);
      expect(firmaValida(cuerpo, cabeceras({ 'x-loyverse-signature': firmar(cuerpo) }), SECRETO).valida)
        .toBe(false);
    });
  });
});

describe('lectura del envío', () => {
  const recibo = { receipt_number: '1-1049', line_items: [] };

  it('entiende las envolturas conocidas', () => {
    expect(extraerRecibos({ receipts: [recibo] })).toHaveLength(1);
    expect(extraerRecibos({ data: [recibo] })).toHaveLength(1);
    expect(extraerRecibos(recibo)).toHaveLength(1);
  });

  it('descarta lo que no son recibos sin reventar', () => {
    // Loyverse avisa de otros objetos: clientes, inventario. No son un error.
    expect(extraerRecibos({ customers: [{ id: 'x' }] })).toHaveLength(0);
    expect(extraerRecibos({ receipts: [{ sin: 'numero' }] })).toHaveLength(0);
    expect(extraerRecibos(null)).toHaveLength(0);
    expect(extraerRecibos('texto suelto')).toHaveLength(0);
  });
});

describe('mapeo de artículos', () => {
  const MAPEO: Mapeo[] = [
    { codigo_externo: 'var-eth-250', sku: 'ETHYIR-F250G' },
    { codigo_externo: 'LV-1002', sku: 'COLHUI-F250G' },
  ];

  const recibo = (items: Recibo['line_items']): Recibo => ({
    receipt_number: '1-1049', receipt_type: 'SALE', line_items: items,
  });

  it('prefiere el identificador de variante, que es el estable', () => {
    expect(clavesDe({ variant_id: 'v', sku: 's', item_id: 'i', quantity: 1 }))
      .toEqual(['v', 's', 'i']);
  });

  it('mapea por variante y por SKU', () => {
    const r = mapearRecibo(recibo([
      { variant_id: 'var-eth-250', quantity: 2, price: 12.5 },
      { sku: 'LV-1002', quantity: 1, price: 11 },
    ]), MAPEO);
    expect(r.sinMapear).toHaveLength(0);
    expect(r.lineas).toEqual([
      { sku: 'ETHYIR-F250G', cantidad: 2, precio_unit: 12.5 },
      { sku: 'COLHUI-F250G', cantidad: 1, precio_unit: 11 },
    ]);
  });

  it('junta las líneas repetidas del mismo artículo', () => {
    // El TPV puede partir una venta en varias líneas; el pedido las quiere juntas.
    const r = mapearRecibo(recibo([
      { variant_id: 'var-eth-250', quantity: 2, price: 12.5 },
      { variant_id: 'var-eth-250', quantity: 3, price: 12.5 },
    ]), MAPEO);
    expect(r.lineas).toHaveLength(1);
    expect(r.lineas[0]!.cantidad).toBe(5);
  });

  it('señala lo que no conoce en vez de ignorarlo', () => {
    const r = mapearRecibo(recibo([
      { variant_id: 'var-eth-250', quantity: 1 },
      { variant_id: 'desconocido', item_name: 'Tarta de zanahoria', quantity: 1 },
    ]), MAPEO);
    expect(r.lineas).toHaveLength(1);
    expect(r.sinMapear).toEqual([
      { codigo: 'desconocido', nombre: 'Tarta de zanahoria', cantidad: 1 },
    ]);
  });

  it('trata las cantidades de una devolución como positivas', () => {
    const r = mapearRecibo(recibo([{ variant_id: 'var-eth-250', quantity: -2 }]), MAPEO);
    expect(r.lineas[0]!.cantidad).toBe(2);
  });

  it('salta las líneas de cantidad cero', () => {
    const r = mapearRecibo(recibo([{ variant_id: 'var-eth-250', quantity: 0 }]), MAPEO);
    expect(r.lineas).toHaveLength(0);
  });
});

describe('datos del recibo', () => {
  it('prefiere la fecha del recibo a la de creación', () => {
    const cuando = momentoDe({
      receipt_number: '1', receipt_date: '2026-09-14T18:20:00Z', created_at: '2026-09-15T09:00:00Z',
    });
    expect(cuando).toBe('2026-09-14T18:20:00.000Z');
  });

  it('aguanta una fecha ilegible sin romper la venta', () => {
    const cuando = momentoDe({ receipt_number: '1', receipt_date: 'ayer por la tarde' });
    expect(Number.isNaN(new Date(cuando).getTime())).toBe(false);
  });

  it('saca la forma de pago', () => {
    expect(formaPagoDe({ receipt_number: '1', payments: [{ name: 'Efectivo' }] })).toBe('Efectivo');
    expect(formaPagoDe({ receipt_number: '1', payments: [{ type: 'CASH' }] })).toBe('CASH');
    expect(formaPagoDe({ receipt_number: '1' })).toBeNull();
  });
});
