import { describe, it, expect } from 'vitest';
import { createHmac } from 'node:crypto';
import { normalizar, reconocer } from '../consultas';
import { firmaValida, extraerMensajes, esCodigo, trocear } from '../instagram';

const SECRETO = 'secreto-de-la-app-de-meta';
const firmar = (c: string, s = SECRETO) =>
  'sha256=' + createHmac('sha256', s).update(c, 'utf8').digest('hex');
const cab = (v: Record<string, string>) => new Headers(v);

describe('reconocer la pregunta', () => {
  it('quita acentos y mayúsculas', () => {
    // Nadie escribe «depósito» con tilde desde un móvil.
    expect(normalizar('Depósito  ')).toBe('deposito');
    expect(normalizar('FRESCURA')).toBe('frescura');
  });

  it('entiende las preguntas corrientes', () => {
    const casos: [string, string][] = [
      ['ayuda', 'ayuda'],
      ['hola', 'ayuda'],
      ['cuánto stock hay', 'stock'],
      ['qué queda de etiopía', 'stock'],
      ['pedidos pendientes', 'pedidos'],
      ['cómo va el depósito', 'deposito'],
      ['el corte inglés', 'deposito'],
      ['qué lotes están viejos', 'frescura'],
      ['kilos de verde', 'verde'],
      ['qué está bajo mínimo', 'minimos'],
      ['ventas de la semana', 'ventas'],
      ['hay incidencias', 'incidencias'],
      ['últimos tuestes', 'tuestes'],
    ];
    for (const [pregunta, esperada] of casos) {
      expect(reconocer(pregunta).intencion, pregunta).toBe(esperada);
    }
  });

  it('lo específico gana a lo general', () => {
    // «stock en depósito» es una pregunta de depósito, no de stock general.
    expect(reconocer('cuánto stock hay en depósito').intencion).toBe('deposito');
    expect(reconocer('stock que esté viejo').intencion).toBe('frescura');
  });

  it('saca el término de búsqueda del resto de la frase', () => {
    expect(reconocer('stock etiopia').resto).toBe('etiopia');
    expect(reconocer('stock').resto).toBe('');
  });

  it('un nombre suelto se entiende como pregunta de stock', () => {
    const r = reconocer('yirgacheffe');
    expect(r.intencion).toBe('stock');
    expect(r.resto).toBe('yirgacheffe');
  });

  it('un mensaje vacío no se inventa una intención', () => {
    expect(reconocer('  ').intencion).toBe('desconocida');
  });
});

describe('firma de Meta', () => {
  const cuerpo = '{"object":"instagram","entry":[]}';

  it('acepta la firma correcta', () => {
    expect(firmaValida(cuerpo, cab({ 'x-hub-signature-256': firmar(cuerpo) }), SECRETO).valida)
      .toBe(true);
  });

  it('rechaza un cuerpo manipulado después de firmar', () => {
    const firma = firmar(cuerpo);
    expect(firmaValida('{"object":"otro","entry":[]}', cab({ 'x-hub-signature-256': firma }), SECRETO)
      .valida).toBe(false);
  });

  it('rechaza un envío sin firma cuando hay secreto', () => {
    expect(firmaValida(cuerpo, cab({}), SECRETO).valida).toBe(false);
  });
});

describe('lectura de los mensajes', () => {
  const envio = (mensaje: Record<string, unknown>) => ({
    object: 'instagram',
    entry: [{ messaging: [{ sender: { id: '17841400000000000' }, message: mensaje }] }],
  });

  it('saca el texto y quién lo manda', () => {
    const m = extraerMensajes(envio({ mid: 'm1', text: 'stock' }));
    expect(m).toEqual([{ remitente: '17841400000000000', texto: 'stock', id: 'm1' }]);
  });

  it('descarta los ecos del propio bot', () => {
    // Sin esto el bot se respondería a sí mismo, en bucle y sin parar.
    expect(extraerMensajes(envio({ mid: 'm2', text: 'Stock:', is_echo: true }))).toHaveLength(0);
  });

  it('ignora mensajes borrados, reacciones y «visto»', () => {
    expect(extraerMensajes(envio({ mid: 'm3', text: 'x', is_deleted: true }))).toHaveLength(0);
    expect(extraerMensajes({
      object: 'instagram',
      entry: [{ messaging: [{ sender: { id: '1' }, reaction: { emoji: '❤️' } }] }],
    })).toHaveLength(0);
  });

  it('aguanta un envío con forma inesperada', () => {
    expect(extraerMensajes(null)).toHaveLength(0);
    expect(extraerMensajes({ entry: [{}] })).toHaveLength(0);
    expect(extraerMensajes('texto suelto')).toHaveLength(0);
  });
});

describe('código de alta', () => {
  it('reconoce un código bien escrito, con espacios o en minúsculas', () => {
    expect(esCodigo('ABC234')).toBe('ABC234');
    expect(esCodigo(' abc234 ')).toBe('ABC234');
  });

  it('no confunde una pregunta con un código', () => {
    expect(esCodigo('stock')).toBeNull();      // cinco letras
    expect(esCodigo('pedidos')).toBeNull();
    expect(esCodigo('ABC23')).toBeNull();      // cinco caracteres
  });

  it('rechaza las letras y cifras que se confunden al leerlas', () => {
    // El alfabeto excluye O/0 e I/1 a propósito: se teclea mirando otra pantalla.
    expect(esCodigo('ABC2O4')).toBeNull();
    expect(esCodigo('ABC2I4')).toBeNull();
  });
});

describe('troceado de la respuesta', () => {
  it('deja en paz lo que cabe', () => {
    expect(trocear('stock: 12')).toEqual(['stock: 12']);
  });

  it('parte por líneas, no por la mitad de una palabra', () => {
    const largo = Array.from({ length: 200 }, (_, i) => `Café número ${i}: 24 paquetes`).join('\n');
    const trozos = trocear(largo);
    expect(trozos.length).toBeGreaterThan(1);
    for (const t of trozos) {
      expect(t.length).toBeLessThanOrEqual(900);
      expect(t.endsWith('paquetes')).toBe(true);
    }
  });

  it('no manda más de cuatro mensajes seguidos', () => {
    const enorme = Array.from({ length: 5000 }, () => 'línea de relleno').join('\n');
    expect(trocear(enorme).length).toBeLessThanOrEqual(4);
  });
});
