'use client';

/**
 * Generación de etiquetas en PDF.
 *
 * Hay dos diseños y no son intercambiables:
 *
 *   VENTA PROPIA — QR con el identificador del LOTE. Cambia con cada tueste
 *     y es lo que da trazabilidad y control de frescura. Lo lee la cámara de
 *     un móvil, que es con lo que se trabaja en el almacén.
 *
 *   EL CORTE INGLÉS — EAN-13 con el código del PRODUCTO. No cambia nunca, lo
 *     lee la caja de una tienda y no sirve para trazabilidad. Por eso hay que
 *     seguir usando el QR para el control interno.
 *
 * La norma GS1 permite imprimir el EAN entre el 80 % y el 200 % de su tamaño
 * nominal. Por debajo del 80 % los lectores de caja empiezan a fallar, así
 * que el generador calcula la escala y avisa cuando no cabe en condiciones.
 */
import { jsPDF } from 'jspdf';
import QRCode from 'qrcode';
import {
  barrasEan13, eanValido, escalaPara,
  MODULO_MM, MODULOS_SIMBOLO, ZONA_IZQ, ANCHO_NOMINAL_MM,
  GS1_MIN, GS1_MAX,
} from './ean13';

export { eanValido, GS1_MIN, GS1_MAX };

/** Altura de las barras al 100 %, sin contar las cifras (GS1). */
const EAN_ALTO_BARRAS = 22.85;
/** Lo que bajan las guardas por debajo del resto, en módulos. */
const GUARDA_EXTRA = 5;

export interface Papel {
  id: string;
  nombre: string;
  /** Rollo térmico: una etiqueta por página, ancho continuo. */
  rollo: boolean;
  anchoPagina: number;
  altoPagina: number;
  columnas: number;
  filas: number;
  ancho: number;
  alto: number;
  margenIzq: number;
  margenSup: number;
  separacionX: number;
  separacionY: number;
}

export const PAPELES: Papel[] = [
  {
    id: 'A4-70x37', nombre: 'A4 · 70 × 37 mm (24 por hoja)', rollo: false,
    anchoPagina: 210, altoPagina: 297, columnas: 3, filas: 8,
    ancho: 70, alto: 37, margenIzq: 0, margenSup: 0, separacionX: 0, separacionY: 0,
  },
  {
    id: 'A4-63x38', nombre: 'A4 · 63,5 × 38,1 mm (21 por hoja)', rollo: false,
    anchoPagina: 210, altoPagina: 297, columnas: 3, filas: 7,
    ancho: 63.5, alto: 38.1, margenIzq: 7.25, margenSup: 15.15, separacionX: 2.5, separacionY: 0,
  },
  {
    id: 'A4-105x48', nombre: 'A4 · 105 × 48 mm (12 por hoja)', rollo: false,
    anchoPagina: 210, altoPagina: 297, columnas: 2, filas: 6,
    ancho: 105, alto: 48, margenIzq: 0, margenSup: 4.5, separacionX: 0, separacionY: 0,
  },
  {
    id: 'A4-99x57', nombre: 'A4 · 99,1 × 57 mm (10 por hoja)', rollo: false,
    anchoPagina: 210, altoPagina: 297, columnas: 2, filas: 5,
    ancho: 99.1, alto: 57, margenIzq: 5.9, margenSup: 6, separacionX: 0, separacionY: 0,
  },
  {
    id: 'ROLLO-58', nombre: 'Rollo térmico 58 mm', rollo: true,
    anchoPagina: 58, altoPagina: 40, columnas: 1, filas: 1,
    ancho: 58, alto: 40, margenIzq: 0, margenSup: 0, separacionX: 0, separacionY: 0,
  },
  {
    id: 'ROLLO-80', nombre: 'Rollo térmico 80 mm', rollo: true,
    anchoPagina: 80, altoPagina: 50, columnas: 1, filas: 1,
    ancho: 80, alto: 50, margenIzq: 0, margenSup: 0, separacionX: 0, separacionY: 0,
  },
];

export type TipoEtiqueta = 'PROPIA' | 'ECI';

export interface DatosEtiqueta {
  loteId: string;
  cafe: string;
  origen?: string | null;
  perfilTueste?: string | null;
  formato?: string | null;
  gramos?: number | null;
  molienda?: string | null;
  fechaTostado?: string | null;
  consumoPreferente?: string | null;
  ean13?: string | null;
}

export interface Opciones {
  datos: DatosEtiqueta;
  tipo: TipoEtiqueta;
  papel: Papel;
  cantidad: number;
  empresa?: string;
  textoLegal?: string;
  /** Para no gastar una hoja entera cuando quedan huecos usados. */
  saltar?: number;
}

export interface Resultado {
  blob: Blob;
  escalaEan: number | null;
  aviso: string | null;
  paginas: number;
}

const fecha = (iso?: string | null) =>
  iso ? new Date(`${iso}T12:00:00`).toLocaleDateString('es-ES') : '';

async function imagenQr(texto: string, lado: number): Promise<string> {
  return QRCode.toDataURL(texto, {
    errorCorrectionLevel: 'M',
    margin: 0,
    // Se genera a resolución generosa: el PDF lo reescala y un QR pixelado
    // es un QR que no lee la cámara con poca luz.
    width: Math.max(256, Math.round(lado * 12)),
    color: { dark: '#000000', light: '#ffffff' },
  });
}

/**
 * Dibuja el código de barras como vectores. La zona tranquila (el blanco a
 * los lados) es parte del símbolo, no un margen decorativo: sin ella el
 * lector no encuentra dónde empieza.
 */
function dibujarEan(
  pdf: jsPDF, codigo: string, centroX: number, baseY: number, escala: number, altoMax: number,
) {
  const modulo = MODULO_MM * escala;
  const anchoSimbolo = MODULOS_SIMBOLO * modulo;
  const altoBarras = Math.min(EAN_ALTO_BARRAS * escala, altoMax - 3 * escala);
  const extra = GUARDA_EXTRA * modulo;
  const x0 = centroX - anchoSimbolo / 2;
  const yTexto = baseY;
  const yBarras = yTexto - altoBarras;

  pdf.setFillColor(0, 0, 0);
  for (const b of barrasEan13(codigo)) {
    pdf.rect(
      x0 + b.desde * modulo,
      yBarras,
      b.ancho * modulo,
      altoBarras + (b.larga ? extra : 0),
      'F',
    );
  }

  // Cifras legibles: la primera fuera del símbolo, a la izquierda, y las
  // otras doce repartidas bajo cada mitad.
  pdf.setFont('helvetica', 'normal');
  pdf.setFontSize(Math.max(4, 7 * escala));
  const yCifras = yTexto + extra + 1.6 * escala;

  pdf.text(codigo[0]!, x0 - ZONA_IZQ * modulo * 0.55, yCifras);
  const izquierda = codigo.slice(1, 7);
  const derecha = codigo.slice(7);
  for (let i = 0; i < 6; i++) {
    pdf.text(izquierda[i]!, x0 + (3 + i * 7 + 3.5) * modulo, yCifras, { align: 'center' });
    pdf.text(derecha[i]!, x0 + (50 + i * 7 + 3.5) * modulo, yCifras, { align: 'center' });
  }
}

export async function generarEtiquetas(o: Opciones): Promise<Resultado> {
  const { papel, datos, tipo } = o;
  const pdf = new jsPDF({
    unit: 'mm',
    format: papel.rollo ? [papel.anchoPagina, papel.altoPagina] : 'a4',
    orientation: 'portrait',
  });

  let escalaEan: number | null = null;
  let aviso: string | null = null;

  if (tipo === 'ECI') {
    if (!eanValido(datos.ean13)) {
      throw new Error(
        'Esta referencia no tiene un EAN-13 válido asignado. '
        + 'Asígnalo en Ajustes antes de imprimir etiquetas para El Corte Inglés.',
      );
    }
    // Se reserva el ancho de la etiqueta menos los márgenes laterales.
    const calculo = escalaPara(papel.ancho - 8);
    escalaEan = calculo.escala;
    if (!calculo.suficiente) {
      aviso = `El código saldría al ${Math.round(escalaEan * 100)} % y la norma GS1 exige `
            + `al menos el 80 %. Con este papel los lectores de caja pueden fallar: `
            + `usa una etiqueta más ancha.`;
    }
  }

  const qr = tipo === 'PROPIA'
    ? await imagenQr(datos.loteId, Math.min(papel.ancho, papel.alto) * 0.55)
    : null;
  const porPagina = papel.columnas * papel.filas;
  let indice = o.saltar ?? 0;
  let paginas = 1;

  for (let n = 0; n < o.cantidad; n++) {
    if (indice >= porPagina) {
      pdf.addPage();
      paginas++;
      indice = 0;
    }

    const col = indice % papel.columnas;
    const fil = Math.floor(indice / papel.columnas);
    const x = papel.margenIzq + col * (papel.ancho + papel.separacionX);
    const y = papel.margenSup + fil * (papel.alto + papel.separacionY);

    if (tipo === 'PROPIA') dibujarPropia(pdf, x, y, papel, datos, qr!, o);
    else dibujarEci(pdf, x, y, papel, datos, escalaEan!, o);

    indice++;
  }

  return { blob: pdf.output('blob'), escalaEan, aviso, paginas };
}

/* ── Diseño de venta propia ──
   El QR manda: es lo que se escanea cien veces al día. Ocupa el lado
   izquierdo entero y el texto se acomoda alrededor. */
function dibujarPropia(
  pdf: jsPDF, x: number, y: number, papel: Papel,
  d: DatosEtiqueta, qr: string, o: Opciones,
) {
  const m = 3;
  const ladoQr = Math.min(papel.alto - m * 2, papel.ancho * 0.36);
  pdf.addImage(qr, 'PNG', x + m, y + (papel.alto - ladoQr) / 2, ladoQr, ladoQr);

  const tx = x + m + ladoQr + 2.5;
  const ancho = papel.ancho - (m + ladoQr + 2.5) - m;
  let ty = y + m + 3;

  pdf.setFont('helvetica', 'bold');
  pdf.setFontSize(papel.ancho > 80 ? 10 : 8);
  for (const linea of pdf.splitTextToSize(d.cafe, ancho).slice(0, 2) as string[]) {
    pdf.text(linea, tx, ty);
    ty += papel.ancho > 80 ? 4 : 3.2;
  }

  pdf.setFont('helvetica', 'normal');
  pdf.setFontSize(papel.ancho > 80 ? 8 : 6.5);
  const sub = [d.origen, d.perfilTueste].filter(Boolean).join(' · ');
  if (sub) { pdf.text(sub, tx, ty); ty += 3; }
  if (d.formato) { pdf.text(d.formato, tx, ty); ty += 3; }

  ty = y + papel.alto - m - (o.textoLegal ? 6.5 : 3.5);
  pdf.setFontSize(papel.ancho > 80 ? 7 : 5.6);
  if (d.fechaTostado) { pdf.text(`Tostado ${fecha(d.fechaTostado)}`, tx, ty); ty += 2.8; }
  if (d.consumoPreferente) { pdf.text(`Consumir antes de ${fecha(d.consumoPreferente)}`, tx, ty); ty += 2.8; }
  if (o.textoLegal) {
    pdf.setFontSize(5);
    pdf.text(pdf.splitTextToSize(o.textoLegal, ancho)[0] as string, tx, ty);
  }

  // El identificador del lote, impreso también en claro: si el QR se borra
  // o la bolsa se arruga, la trazabilidad no se pierde.
  pdf.setFontSize(4.5);
  pdf.setTextColor(110);
  pdf.text(d.loteId, x + m, y + papel.alto - 1.2);
  pdf.setTextColor(0);
}

/* ── Diseño de El Corte Inglés ──
   Manda el código de barras, que es lo que tiene que leer su caja sin
   reintentos. El resto es lo que exige la trazabilidad, en pequeño. */
function dibujarEci(
  pdf: jsPDF, x: number, y: number, papel: Papel,
  d: DatosEtiqueta, escala: number, o: Opciones,
) {
  const m = 3;
  let ty = y + m + 2.8;

  pdf.setFont('helvetica', 'bold');
  pdf.setFontSize(papel.ancho > 80 ? 9 : 7.5);
  for (const linea of pdf.splitTextToSize(d.cafe, papel.ancho - m * 2).slice(0, 2) as string[]) {
    pdf.text(linea, x + m, ty);
    ty += papel.ancho > 80 ? 3.6 : 3;
  }

  pdf.setFont('helvetica', 'normal');
  pdf.setFontSize(papel.ancho > 80 ? 7.5 : 6.2);
  const peso = d.gramos ? (d.gramos >= 1000 ? `${d.gramos / 1000} kg` : `${d.gramos} g`) : '';
  const linea2 = [peso && `Peso neto ${peso}`, d.molienda?.toLowerCase()].filter(Boolean).join(' · ');
  if (linea2) { pdf.text(linea2, x + m, ty); ty += 3; }
  if (d.consumoPreferente) {
    pdf.text(`Consumo preferente ${fecha(d.consumoPreferente)}`, x + m, ty);
    ty += 3;
  }
  pdf.setFontSize(5.2);
  pdf.setTextColor(110);
  pdf.text(`Lote ${d.loteId}`, x + m, ty);
  pdf.setTextColor(0);

  dibujarEan(
    pdf, d.ean13!,
    x + papel.ancho / 2,
    y + papel.alto - m - 2.2 * escala,
    escala,
    papel.alto - (ty - y) - m,
  );
  void ANCHO_NOMINAL_MM;

  if (o.empresa) {
    pdf.setFontSize(5);
    pdf.setTextColor(110);
    pdf.text(o.empresa, x + papel.ancho - m, y + m, { align: 'right' });
    pdf.setTextColor(0);
  }
}
