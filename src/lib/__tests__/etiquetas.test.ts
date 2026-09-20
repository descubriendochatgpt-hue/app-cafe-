import { describe, it, expect } from 'vitest';
import { generarEtiquetas, PAPELES, type DatosEtiqueta } from '../etiquetas';

const LOTE: DatosEtiqueta = {
  loteId: 'CAF-ETHYIR-250-260905-A',
  cafe: 'Etiopía Yirgacheffe',
  origen: 'Etiopía',
  perfilTueste: 'Claro',
  formato: '250 g grano',
  gramos: 250,
  molienda: 'GRANO',
  fechaTostado: '2026-09-05',
  consumoPreferente: '2027-09-05',
  ean13: '8412345000010',
};

const papel = (id: string) => PAPELES.find((p) => p.id === id)!;

async function bytes(blob: Blob): Promise<Buffer> {
  return Buffer.from(await blob.arrayBuffer());
}

describe('etiqueta de venta propia', () => {
  it('genera un PDF válido', async () => {
    const r = await generarEtiquetas({
      datos: LOTE, tipo: 'PROPIA', papel: papel('A4-70x37'), cantidad: 1,
    });
    const b = await bytes(r.blob);
    expect(b.subarray(0, 5).toString()).toBe('%PDF-');
    expect(b.length).toBeGreaterThan(1000);
    expect(r.paginas).toBe(1);
  });

  it('reparte en hojas según caben', async () => {
    // 24 por hoja: 25 etiquetas son dos hojas.
    const una = await generarEtiquetas({ datos: LOTE, tipo: 'PROPIA', papel: papel('A4-70x37'), cantidad: 24 });
    const dos = await generarEtiquetas({ datos: LOTE, tipo: 'PROPIA', papel: papel('A4-70x37'), cantidad: 25 });
    expect(una.paginas).toBe(1);
    expect(dos.paginas).toBe(2);
  });

  it('aprovecha una hoja ya empezada', async () => {
    // Con 20 huecos gastados solo quedan 4 libres: 5 etiquetas pasan a la siguiente.
    const r = await generarEtiquetas({
      datos: LOTE, tipo: 'PROPIA', papel: papel('A4-70x37'), cantidad: 5, saltar: 20,
    });
    expect(r.paginas).toBe(2);
  });

  it('no necesita EAN', async () => {
    const r = await generarEtiquetas({
      datos: { ...LOTE, ean13: null }, tipo: 'PROPIA', papel: papel('ROLLO-58'), cantidad: 1,
    });
    expect(r.escalaEan).toBeNull();
    expect((await bytes(r.blob)).subarray(0, 5).toString()).toBe('%PDF-');
  });
});

describe('etiqueta de El Corte Inglés', () => {
  it('genera el código dentro de lo que permite la norma', async () => {
    const r = await generarEtiquetas({
      datos: LOTE, tipo: 'ECI', papel: papel('A4-70x37'), cantidad: 1,
    });
    expect(r.escalaEan).not.toBeNull();
    expect(r.escalaEan!).toBeGreaterThanOrEqual(0.8);
    expect(r.aviso).toBeNull();
  });

  it('se niega si la referencia no tiene EAN válido', async () => {
    await expect(generarEtiquetas({
      datos: { ...LOTE, ean13: null }, tipo: 'ECI', papel: papel('A4-70x37'), cantidad: 1,
    })).rejects.toThrow(/EAN-13 válido/);

    await expect(generarEtiquetas({
      datos: { ...LOTE, ean13: '8412345000011' }, tipo: 'ECI', papel: papel('A4-70x37'), cantidad: 1,
    })).rejects.toThrow(/EAN-13 válido/);
  });

  it('avisa cuando el papel es tan estrecho que el lector fallaría', async () => {
    // Un rollo de 58 mm menos márgenes deja 50 mm: da de sobra. Se fuerza
    // un papel estrecho para comprobar que el aviso salta.
    const estrecho = { ...papel('ROLLO-58'), ancho: 32, anchoPagina: 32 };
    const r = await generarEtiquetas({
      datos: LOTE, tipo: 'ECI', papel: estrecho, cantidad: 1,
    });
    expect(r.escalaEan!).toBeLessThan(0.8);
    expect(r.aviso).toMatch(/80 %/);
  });

  it('cabe en todos los papeles anchos sin aviso', async () => {
    for (const id of ['A4-70x37', 'A4-105x48', 'A4-99x57', 'ROLLO-58', 'ROLLO-80']) {
      const r = await generarEtiquetas({ datos: LOTE, tipo: 'ECI', papel: papel(id), cantidad: 1 });
      expect(r.aviso, `papel ${id}`).toBeNull();
    }
  });
});
