/**
 * El correo diario. Se comprueba lo que decide si se lee o si se ignora:
 * el asunto, que los nombres lleguen dentro, y que no se cuele HTML ajeno.
 */
import { describe, it, expect } from 'vitest';
import { redactar, resumenSchema, type Resumen } from '../correo';

const vacio: Resumen = resumenSchema.parse({
  fecha: '2026-09-16',
  ventas: { pedidos: 0, total: 0, unidades: 0 },
  canales: [],
  produccion: { tuestes: 0, kg_verde: 0, kg_tostado: 0 },
  minimos: [], frescura: [], incidencias: [], pendientes: [], deposito: [],
  descuadres: 0, solo_si_hay: false, hay_avisos: false,
});

const con = (parte: Partial<Resumen>): Resumen => ({ ...vacio, ...parte } as Resumen);

describe('asunto', () => {
  it('lleva las ventas y cuántas cosas hay que mirar', () => {
    const c = redactar(con({
      ventas: { pedidos: 3, total: 137.5, unidades: 11 },
      minimos: [{ sku: 'ETHYIR-250-GR', quedan: 2, minimo: 6 }],
      hay_avisos: true,
    }));
    expect(c.asunto).toContain('3 pedidos');
    expect(c.asunto).toContain('137,50');
    expect(c.asunto).toContain('1 por mirar');
  });

  it('dice que todo está en orden cuando no hay nada', () => {
    expect(redactar(vacio).asunto).toContain('todo en orden');
    expect(redactar(vacio).asunto).toContain('sin ventas');
  });

  it('concuerda el singular', () => {
    const c = redactar(con({ ventas: { pedidos: 1, total: 25, unidades: 2 } }));
    expect(c.asunto).toContain('1 pedido,');
    expect(c.asunto).not.toContain('1 pedidos');
  });
});

describe('cuerpo', () => {
  it('trae los nombres, no solo las cuentas', () => {
    const c = redactar(con({
      minimos: [{ sku: 'ETHYIR-250-GR', quedan: 2, minimo: 6 }],
      hay_avisos: true,
    }));
    // Lo importante: se puede decidir sin abrir la aplicación.
    expect(c.texto).toContain('ETHYIR-250-GR');
    expect(c.texto).toContain('quedan 2 (mínimo 6)');
    expect(c.html).toContain('ETHYIR-250-GR');
  });

  it('pone el descuadre por delante de todo lo demás', () => {
    const c = redactar(con({
      descuadres: 2, hay_avisos: true,
      minimos: [{ sku: 'X', quedan: 0, minimo: 1 }],
    }));
    expect(c.texto.indexOf('no cuadran')).toBeLessThan(c.texto.indexOf('BAJO MÍNIMOS'));
  });

  it('dice que no hay nada cuando no lo hay', () => {
    expect(redactar(vacio).texto).toContain('Nada que mirar hoy');
    expect(redactar(vacio).html).toContain('Nada que mirar hoy');
  });

  it('incluye el enlace al panel solo si se le da la dirección', () => {
    expect(redactar(vacio, 'https://cafe.example').html).toContain('https://cafe.example/panel');
    expect(redactar(vacio).html).not.toContain('Abrir el panel');
  });

  it('va siempre en texto además de en HTML', () => {
    const c = redactar(vacio);
    expect(c.texto.length).toBeGreaterThan(20);
    expect(c.texto).not.toContain('<');
  });
});

describe('seguridad', () => {
  it('escapa lo que viene de fuera', () => {
    // El nombre del cliente y la referencia del pedido los escribe un tercero
    // (la web, el TPV, un formulario). Si se colaran sin escapar, el correo
    // sería un sitio estupendo para meter un enlace ajeno.
    const c = redactar(con({
      hay_avisos: true,
      pendientes: [{
        pedido: '<img src=x onerror=alert(1)>', canal: 'Online',
        cliente: 'Bar "El Ancla" & Cía', estado: 'CONFIRMADO', desde: '2026-09-15',
      }],
    }));
    expect(c.html).not.toContain('<img src=x');
    expect(c.html).toContain('&lt;img src=x');
    expect(c.html).toContain('&amp; Cía');
    expect(c.html).toContain('&quot;El Ancla&quot;');
  });
});
