/**
 * Codificación EAN-13.
 *
 * Se genera el patrón de módulos y se dibuja como vectores en el PDF, en vez
 * de rasterizar una imagen. Tres razones, y las tres importan cuando el
 * código lo tiene que leer la caja de una tienda ajena:
 *
 *   · las barras salen nítidas a cualquier tamaño, sin bordes difuminados
 *     que confundan al lector;
 *   · el PDF pesa una fracción;
 *   · es lógica pura, así que se puede comprobar con tests en vez de
 *     confiar en que la librería hizo lo correcto.
 *
 * Medidas de la norma GS1: módulo de 0,33 mm al 100 %, símbolo de 95 módulos
 * y 113 contando las zonas tranquilas (11 a la izquierda, 7 a la derecha).
 */

export const MODULO_MM = 0.33;
export const MODULOS_SIMBOLO = 95;
export const ZONA_IZQ = 11;
export const ZONA_DER = 7;
export const MODULOS_TOTALES = ZONA_IZQ + MODULOS_SIMBOLO + ZONA_DER;   // 113
export const ANCHO_NOMINAL_MM = MODULOS_TOTALES * MODULO_MM;            // 37,29 mm
export const ALTO_NOMINAL_MM = 25.93;

const L = [
  '0001101', '0011001', '0010011', '0111101', '0100011',
  '0110001', '0101111', '0111011', '0110111', '0001011',
];
const G = [
  '0100111', '0110011', '0011011', '0100001', '0011101',
  '0111001', '0000101', '0010001', '0001001', '0010111',
];
/** R es el complemento de L. */
const R = L.map((p) => [...p].map((b) => (b === '0' ? '1' : '0')).join(''));

/** Qué mitad izquierda usa L y cuál G, según el primer dígito. */
const PARIDAD = [
  'LLLLLL', 'LLGLGG', 'LLGGLG', 'LLGGGL', 'LGLLGG',
  'LGGLLG', 'LGGGLL', 'LGLGLG', 'LGLGGL', 'LGGLGL',
];

export function digitoControl(doce: string): number {
  let suma = 0;
  for (let i = 0; i < 12; i++) suma += Number(doce[i]) * (i % 2 ? 3 : 1);
  return (10 - (suma % 10)) % 10;
}

export function eanValido(codigo: string | null | undefined): boolean {
  if (!codigo || !/^[0-9]{13}$/.test(codigo)) return false;
  return digitoControl(codigo.slice(0, 12)) === Number(codigo[12]);
}

/** Completa un código de 12 cifras con su dígito de control. */
export function completarEan(doce: string): string {
  if (!/^[0-9]{12}$/.test(doce)) throw new Error('Hacen falta exactamente 12 cifras.');
  return doce + digitoControl(doce);
}

export interface Barra {
  /** Posición en módulos desde el inicio del símbolo (sin zona tranquila). */
  desde: number;
  ancho: number;
  /** Las barras de guarda bajan más que las demás, hasta debajo de las cifras. */
  larga: boolean;
}

/**
 * Convierte el código en barras. Devuelve solo las barras negras: los huecos
 * son el papel.
 */
export function barrasEan13(codigo: string): Barra[] {
  if (!eanValido(codigo)) {
    throw new Error(`EAN-13 inválido: ${codigo}`);
  }

  const paridad = PARIDAD[Number(codigo[0])]!;
  let patron = '101';                       // guarda inicial
  const guardas = new Set<number>();

  const marcarGuarda = (desde: number, largo: number) => {
    for (let i = desde; i < desde + largo; i++) guardas.add(i);
  };
  marcarGuarda(0, 3);

  for (let i = 0; i < 6; i++) {
    const d = Number(codigo[i + 1]);
    patron += paridad[i] === 'L' ? L[d]! : G[d]!;
  }

  marcarGuarda(patron.length, 5);
  patron += '01010';                        // guarda central

  for (let i = 0; i < 6; i++) {
    patron += R[Number(codigo[i + 7])]!;
  }

  marcarGuarda(patron.length, 3);
  patron += '101';                          // guarda final

  // Módulos contiguos del mismo color se funden en una sola barra: es lo que
  // hace que el dibujo sea correcto y no una rejilla de rectángulos pegados.
  const barras: Barra[] = [];
  let i = 0;
  while (i < patron.length) {
    if (patron[i] === '0') { i++; continue; }
    const desde = i;
    while (i < patron.length && patron[i] === '1') i++;
    barras.push({ desde, ancho: i - desde, larga: guardas.has(desde) });
  }
  return barras;
}

export const GS1_MIN = 0.8;
export const GS1_MAX = 2.0;

/**
 * Tamaño al que se imprime cuando hay sitio de sobra.
 *
 * No se estira el código hasta llenar la etiqueta: más grande no se lee
 * mejor a partir de cierto punto, y sí deja sin espacio al peso neto y al
 * número de lote, que son obligatorios para la trazabilidad. El 115 % es el
 * tamaño que ya venía usando la casa en etiquetas de 70 × 37 mm.
 */
export const ESCALA_PREFERIDA = 1.15;

/**
 * Escala a la que imprimir en el ancho disponible. Se queda en la preferida
 * mientras quepa, y solo encoge cuando la etiqueta obliga. `suficiente` dice
 * si respeta el mínimo de la norma: por debajo, los lectores de caja fallan.
 */
export function escalaPara(
  anchoDisponibleMm: number,
  preferida = ESCALA_PREFERIDA,
): { escala: number; suficiente: boolean } {
  const cabe = anchoDisponibleMm / ANCHO_NOMINAL_MM;
  const escala = Math.min(GS1_MAX, preferida, cabe);
  return { escala, suficiente: escala >= GS1_MIN };
}
