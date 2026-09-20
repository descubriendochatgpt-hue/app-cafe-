import { describe, it, expect } from 'vitest';
import { ventaSchema, tuesteSchema, operacionEncolada } from '../inventario';

const AHORA = '2026-09-20T10:00:00+02:00';
const OP = '22222222-2222-4222-8222-222222222222';

const ventaValida = {
  operacionId: OP,
  ubicacionId: 'TIENDA',
  lineas: [{ sku: 'ETHYIR-250-GR', cantidad: 2, precio_unit: 12.5 }],
  ocurridoEn: AHORA,
};

describe('validación de ventas', () => {
  it('acepta una venta bien formada y pone el canal por defecto', () => {
    const r = ventaSchema.parse(ventaValida);
    expect(r.canal).toBe('Mostrador');
    expect(r.origen).toBe('app');
  });

  it('exige que el identificador de operación sea un UUID', () => {
    // Si el móvil no genera un UUID, la idempotencia deja de funcionar.
    expect(() => ventaSchema.parse({ ...ventaValida, operacionId: 'venta-1' })).toThrow();
  });

  it('rechaza una venta sin líneas', () => {
    expect(() => ventaSchema.parse({ ...ventaValida, lineas: [] })).toThrow();
  });

  it('rechaza cantidades negativas o cero', () => {
    for (const cantidad of [0, -1]) {
      expect(() => ventaSchema.parse({
        ...ventaValida,
        lineas: [{ sku: 'ETHYIR-250-GR', cantidad }],
      })).toThrow();
    }
  });

  it('rechaza una fecha sin zona horaria', () => {
    // Una venta encolada en un mercado se sube horas después: sin huso, la
    // hora del hecho sería la de llegada al servidor.
    expect(() => ventaSchema.parse({ ...ventaValida, ocurridoEn: '2026-09-20T10:00:00' })).toThrow();
  });

  it('rechaza un origen que no es un canal conocido', () => {
    expect(() => ventaSchema.parse({ ...ventaValida, origen: 'telepatia' })).toThrow();
  });

  it('acepta un lote explícito cuando se ha escaneado la bolsa', () => {
    const r = ventaSchema.parse({
      ...ventaValida,
      lineas: [{ sku: 'ETHYIR-250-GR', cantidad: 1, lote_id: 'CAF-ETHYIR-250-260905-A' }],
    });
    expect(r.lineas[0]?.lote_id).toBe('CAF-ETHYIR-250-260905-A');
  });
});

describe('validación de tuestes', () => {
  it('exige consumo de verde y producción', () => {
    const base = {
      operacionId: OP,
      ubicacionId: 'ALMACEN',
      consumos: [{ lote_id: 'VRD-ETHYIR-260901-A', cantidad: 20 }],
      producciones: [{ sku: 'ETHYIR-250-GR', cantidad: 65 }],
      ocurridoEn: AHORA,
    };
    expect(() => tuesteSchema.parse(base)).not.toThrow();
    expect(() => tuesteSchema.parse({ ...base, consumos: [] })).toThrow();
    expect(() => tuesteSchema.parse({ ...base, producciones: [] })).toThrow();
  });

  it('admite varios sacos de origen, que es la mezcla de la casa', () => {
    const r = tuesteSchema.parse({
      operacionId: OP,
      ubicacionId: 'ALMACEN',
      consumos: [
        { lote_id: 'VRD-BRASIL-260901-A', cantidad: 12 },
        { lote_id: 'VRD-COLHUI-260903-A', cantidad: 8 },
      ],
      producciones: [{ sku: 'MEZCLA-250-GR', cantidad: 65 }],
      ocurridoEn: AHORA,
    });
    expect(r.consumos).toHaveLength(2);
  });
});

describe('cola offline', () => {
  it('distingue el tipo de operación encolada', () => {
    const r = operacionEncolada.parse({ tipo: 'VENTA', datos: ventaValida });
    expect(r.tipo).toBe('VENTA');
  });

  it('rechaza un tipo que el despachador no sabe atender', () => {
    expect(() => operacionEncolada.parse({ tipo: 'FACTURAR', datos: ventaValida })).toThrow();
  });
});
