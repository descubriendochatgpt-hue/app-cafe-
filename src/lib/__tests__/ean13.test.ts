import { describe, it, expect } from 'vitest';
import {
  digitoControl, eanValido, completarEan, barrasEan13, escalaPara,
  MODULOS_SIMBOLO, ANCHO_NOMINAL_MM, GS1_MIN,
} from '../ean13';

describe('dígito de control', () => {
  it('calcula el de códigos conocidos', () => {
    // Códigos reales de productos, con su dígito de control publicado.
    expect(completarEan('978020137962')).toBe('9780201379624');
    expect(completarEan('400638133393')).toBe('4006381333931');
    expect(digitoControl('841234500001')).toBe(0);
  });

  it('acepta los válidos y rechaza los que no lo son', () => {
    expect(eanValido('9780201379624')).toBe(true);
    expect(eanValido('9780201379625')).toBe(false);   // dígito cambiado
    expect(eanValido('978020137962')).toBe(false);    // 12 cifras
    expect(eanValido('84123450000A')).toBe(false);    // una letra
    expect(eanValido(null)).toBe(false);
  });

  it('exige doce cifras exactas para completar', () => {
    expect(() => completarEan('12345')).toThrow();
  });
});

describe('patrón de barras', () => {
  const CODIGO = '9780201379624';

  it('ocupa exactamente los 95 módulos que manda la norma', () => {
    const barras = barrasEan13(CODIGO);
    const ultima = barras[barras.length - 1]!;
    expect(ultima.desde + ultima.ancho).toBe(MODULOS_SIMBOLO);
  });

  it('coloca las tres guardas donde corresponde', () => {
    const largas = barrasEan13(CODIGO).filter((b) => b.larga);
    // Guarda inicial (101 → dos barras), central (01010 → dos) y final (dos).
    expect(largas).toHaveLength(6);
    expect(largas[0]!.desde).toBe(0);
    expect(largas[2]!.desde).toBe(46);   // guarda central: 3 + 42 + 1
    expect(largas[5]!.desde).toBe(94);   // última barra del símbolo
  });

  it('ninguna barra se sale ni se solapa', () => {
    const barras = barrasEan13(CODIGO);
    let anterior = -1;
    for (const b of barras) {
      expect(b.desde).toBeGreaterThan(anterior);
      expect(b.ancho).toBeGreaterThanOrEqual(1);
      expect(b.ancho).toBeLessThanOrEqual(4);
      expect(b.desde + b.ancho).toBeLessThanOrEqual(MODULOS_SIMBOLO);
      anterior = b.desde + b.ancho - 1;
    }
  });

  it('códigos distintos dan patrones distintos', () => {
    const a = JSON.stringify(barrasEan13('8412345000010'));
    const b = JSON.stringify(barrasEan13('8412345000027'));
    expect(a).not.toBe(b);
  });

  it('el primer dígito cambia la paridad de la mitad izquierda', () => {
    // Mismos últimos doce dígitos, distinto primero: la mitad izquierda
    // tiene que codificarse de otra manera aunque las cifras coincidan.
    const uno = barrasEan13(completarEan('012345678912'));
    const otro = barrasEan13(completarEan('112345678912'));
    expect(JSON.stringify(uno)).not.toBe(JSON.stringify(otro));
  });

  it('se niega a dibujar un código inválido', () => {
    expect(() => barrasEan13('9780201379625')).toThrow(/inválido/);
  });
});

describe('escala GS1', () => {
  it('el ancho nominal es el de la norma', () => {
    expect(ANCHO_NOMINAL_MM).toBeCloseTo(37.29, 2);
  });

  it('en 70 × 37 mm sale al 115 %, como en el sistema anterior', () => {
    const { escala, suficiente } = escalaPara(70 - 8);
    expect(suficiente).toBe(true);
    expect(Math.round(escala * 100)).toBe(115);
  });

  it('encoge solo cuando la etiqueta obliga', () => {
    // 40 mm de ancho no dan para el 115 %, pero sí superan el mínimo.
    const { escala, suficiente } = escalaPara(40);
    expect(suficiente).toBe(true);
    expect(escala).toBeLessThan(1.15);
    expect(escala).toBeGreaterThan(0.8);
  });

  it('avisa cuando el papel es demasiado estrecho', () => {
    const { escala, suficiente } = escalaPara(25);
    expect(suficiente).toBe(false);
    expect(escala).toBeLessThan(GS1_MIN);
  });

  it('no se estira más de lo necesario aunque sobre sitio', () => {
    expect(escalaPara(500).escala).toBe(1.15);
    // Solo si se pide expresamente más, y nunca por encima del 200 %.
    expect(escalaPara(500, 5).escala).toBe(2);
  });
});
