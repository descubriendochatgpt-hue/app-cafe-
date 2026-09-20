import { describe, it, expect } from 'vitest';
import { normalizar, reconocer } from '../consultas';
import {
  envioAutentico, extraerMensaje, esCodigo, limpiarComando, trocear,
} from '../telegram';

const SECRETO = 'secreto-del-webhook-de-telegram';
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

describe('autenticidad del envío', () => {
  it('acepta el secreto acordado', () => {
    expect(envioAutentico(cab({ 'x-telegram-bot-api-secret-token': SECRETO }), SECRETO).valido)
      .toBe(true);
  });

  it('rechaza otro secreto, y también uno más largo que empiece igual', () => {
    expect(envioAutentico(cab({ 'x-telegram-bot-api-secret-token': 'otro' }), SECRETO).valido)
      .toBe(false);
    expect(envioAutentico(cab({ 'x-telegram-bot-api-secret-token': `${SECRETO}x` }), SECRETO).valido)
      .toBe(false);
  });

  it('rechaza un envío sin el secreto', () => {
    const r = envioAutentico(cab({}), SECRETO);
    expect(r.valido).toBe(false);
    expect(r.motivo).toMatch(/secreto/);
  });

  it('no lo exige si no se ha configurado', () => {
    expect(envioAutentico(cab({}), '').valido).toBe(true);
  });
});

describe('lectura del mensaje', () => {
  const envio = (extra: Record<string, unknown> = {}, chat = { id: 55, type: 'private' }) => ({
    update_id: 1,
    message: {
      message_id: 7,
      from: { id: 55, is_bot: false, first_name: 'Marta', username: 'marta_cafe' },
      chat,
      text: 'stock',
      ...extra,
    },
  });

  it('saca el texto, quién lo manda y su alias', () => {
    expect(extraerMensaje(envio())).toEqual({
      chat: 55, remitente: '55', texto: 'stock', nombre: 'Marta', alias: 'marta_cafe',
    });
  });

  it('ignora los mensajes de otros bots', () => {
    // Dos bots hablándose producirían un bucle que no para solo.
    expect(extraerMensaje(envio({
      from: { id: 99, is_bot: true, first_name: 'OtroBot' },
    }))).toBeNull();
  });

  it('SOLO atiende en conversación privada', () => {
    // Es lo más importante de esta función: en un grupo verían la respuesta
    // personas que no están autorizadas, aunque quien pregunte sí lo esté.
    expect(extraerMensaje(envio({}, { id: -100, type: 'group' }))).toBeNull();
    expect(extraerMensaje(envio({}, { id: -100, type: 'supergroup' }))).toBeNull();
    expect(extraerMensaje(envio({}, { id: -100, type: 'channel' }))).toBeNull();
  });

  it('ignora ediciones y envíos sin texto', () => {
    expect(extraerMensaje({ update_id: 2, edited_message: { text: 'stock' } })).toBeNull();
    expect(extraerMensaje(envio({ text: undefined }))).toBeNull();
  });

  it('aguanta un envío con forma inesperada', () => {
    expect(extraerMensaje(null)).toBeNull();
    expect(extraerMensaje({})).toBeNull();
    expect(extraerMensaje('texto suelto')).toBeNull();
  });
});

describe('código de alta', () => {
  it('lo reconoce escrito a mano', () => {
    expect(esCodigo('ABC234')).toBe('ABC234');
    expect(esCodigo(' abc234 ')).toBe('ABC234');
  });

  it('lo reconoce dentro del /start del enlace de alta', () => {
    // Es lo que manda Telegram al abrir t.me/elbot?start=ABC234
    expect(esCodigo('/start ABC234')).toBe('ABC234');
    expect(esCodigo('/start abc234')).toBe('ABC234');
  });

  it('no confunde una pregunta con un código', () => {
    expect(esCodigo('stock')).toBeNull();
    expect(esCodigo('pedidos')).toBeNull();
    expect(esCodigo('/start')).toBeNull();
  });

  it('rechaza las letras y cifras que se confunden al leerlas', () => {
    expect(esCodigo('ABC2O4')).toBeNull();
    expect(esCodigo('ABC2I4')).toBeNull();
  });
});

describe('comandos', () => {
  it('trata /stock y stock como la misma pregunta', () => {
    expect(limpiarComando('/stock etiopía')).toBe('stock etiopía');
    expect(limpiarComando('stock etiopía')).toBe('stock etiopía');
  });

  it('quita la mención al bot que añade Telegram en los grupos', () => {
    expect(limpiarComando('/stock@cafebot etiopía')).toBe('stock etiopía');
  });
});

describe('troceado de la respuesta', () => {
  it('deja en paz lo que cabe', () => {
    expect(trocear('stock: 12')).toEqual(['stock: 12']);
  });

  it('parte por líneas, no por la mitad de una palabra', () => {
    const largo = Array.from({ length: 400 }, (_, i) => `Café número ${i}: 24 paquetes`).join('\n');
    const trozos = trocear(largo);
    expect(trozos.length).toBeGreaterThan(1);
    for (const t of trozos) {
      expect(t.length).toBeLessThanOrEqual(3500);
      expect(t.endsWith('paquetes')).toBe(true);
    }
  });

  it('no manda más de cuatro mensajes seguidos', () => {
    const enorme = Array.from({ length: 5000 }, () => 'línea de relleno').join('\n');
    expect(trocear(enorme).length).toBeLessThanOrEqual(4);
  });
});
