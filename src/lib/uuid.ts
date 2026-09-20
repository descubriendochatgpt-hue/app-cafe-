/**
 * Identificador de operación.
 *
 * Se genera SIEMPRE en el dispositivo que origina el hecho, antes de saber si
 * hay cobertura. Es la pieza de la que depende que subir dos veces la misma
 * venta no la cuente dos veces.
 */
export function nuevaOperacionId(): string {
  const c: Crypto | undefined = typeof crypto === 'undefined' ? undefined : crypto;
  if (!c) throw new Error('Este navegador no puede generar identificadores seguros.');

  if (typeof c.randomUUID === 'function') return c.randomUUID();

  // Safari antiguo o servido sin https: mismo formato, misma validez.
  const b = c.getRandomValues(new Uint8Array(16));
  b[6] = ((b[6] ?? 0) & 0x0f) | 0x40;   // versión 4
  b[8] = ((b[8] ?? 0) & 0x3f) | 0x80;   // variante RFC 4122
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/** Momento actual con huso horario: una venta encolada conserva SU hora. */
export function ahora(): string {
  return new Date().toISOString();
}
