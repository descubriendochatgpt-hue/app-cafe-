'use client';

/**
 * La forma del periodo: cuánto se vendió cada día.
 *
 * Se dibuja en píxeles reales, no en un `viewBox` que luego se estira. Con
 * `viewBox` el mismo gráfico sale con la letra al doble de tamaño en un
 * portátil que en un móvil, y los cantos redondeados se deforman con él.
 * Midiendo el ancho de verdad, una barra mide lo que dice medir en cualquier
 * pantalla.
 *
 * Y de ahí sale también cuántas barras caben. En 365 barras sobre un móvil
 * cada día sería menos de un píxel: en vez de dibujar una empalizada ilegible,
 * se agrupa por semanas o por meses y se dice en el pie qué es cada barra.
 * Agrupar cambia la pregunta que responde el gráfico, así que se cuenta.
 */
import { useEffect, useMemo, useRef, useState } from 'react';

export interface Dia {
  fecha: string;
  pedidos: number;
  unidades: number;
  total: number | null;
}

interface Cubo {
  desde: string;
  hasta: string;
  valor: number;
  pedidos: number;
}

type Grano = 'dia' | 'semana' | 'mes';

const ALTO = 132;
const ARRIBA = 18;   // sitio para la cifra de la barra más alta
const ABAJO = 18;    // sitio para las fechas
const HUECO = 2;     // separación entre barras, en superficie

const GRANOS: Record<Grano, string> = {
  dia: 'por día', semana: 'por semana', mes: 'por mes',
};

function lunes(f: Date): Date {
  const d = new Date(f);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d;
}

function agrupar(dias: Dia[], grano: Grano, valorDe: (d: Dia) => number): Cubo[] {
  const cubos = new Map<string, Cubo>();
  for (const d of dias) {
    const f = new Date(`${d.fecha}T00:00:00Z`);
    const clave = grano === 'dia'
      ? d.fecha
      : grano === 'semana'
        ? lunes(f).toISOString().slice(0, 10)
        : `${d.fecha.slice(0, 7)}-01`;
    const previo = cubos.get(clave);
    if (previo) {
      previo.valor += valorDe(d);
      previo.pedidos += d.pedidos;
      previo.hasta = d.fecha;
    } else {
      cubos.set(clave, { desde: clave, hasta: d.fecha, valor: valorDe(d), pedidos: d.pedidos });
    }
  }
  return [...cubos.values()];
}

/** Último día que cae dentro de un tramo. Sirve para saber si está entero. */
function finDeTramo(desde: string, grano: Grano): string {
  const d = new Date(`${desde}T00:00:00Z`);
  if (grano === 'mes') { d.setUTCMonth(d.getUTCMonth() + 1); d.setUTCDate(0); }
  else if (grano === 'semana') { d.setUTCDate(d.getUTCDate() + 6); }
  return d.toISOString().slice(0, 10);
}

/** Barra con los cantos de arriba redondeados y la base recta, apoyada en el eje. */
function barra(x: number, y: number, ancho: number, base: number): string {
  const alto = base - y;
  const r = Math.min(4, ancho / 2, alto);
  if (alto <= 0) return '';
  return `M${x},${base}L${x},${y + r}Q${x},${y} ${x + r},${y}`
       + `L${x + ancho - r},${y}Q${x + ancho},${y} ${x + ancho},${y + r}`
       + `L${x + ancho},${base}Z`;
}

export function GraficoDiario({ dias, moneda, formato }: {
  dias: Dia[];
  /** Con importes se dibuja el dinero; sin ellos, las unidades servidas. */
  moneda: boolean;
  formato: (n: number) => string;
}) {
  const caja = useRef<HTMLDivElement>(null);
  const [ancho, setAncho] = useState(340);
  const [elegido, setElegido] = useState<number | null>(null);

  useEffect(() => {
    const nodo = caja.current;
    if (!nodo) return;
    const ro = new ResizeObserver((entradas) => {
      const e = entradas[0];
      if (e) setAncho(Math.max(240, e.contentRect.width));
    });
    ro.observe(nodo);
    return () => ro.disconnect();
  }, []);

  const { cubos, grano, tope } = useMemo(() => {
    const valorDe = (d: Dia) => (moneda ? Number(d.total ?? 0) : Number(d.unidades ?? 0));
    const caben = Math.max(6, Math.floor(ancho / 8));
    const g: Grano = dias.length <= caben ? 'dia'
      : Math.ceil(dias.length / 7) <= caben ? 'semana' : 'mes';
    const c = agrupar(dias, g, valorDe);
    return { cubos: c, grano: g, tope: c.reduce((m, x) => Math.max(m, x.valor), 0) };
  }, [dias, ancho, moneda]);

  // El elegido se guarda por índice, y al cambiar de grano los índices dejan
  // de señalar lo mismo. Más vale soltarlo que enseñar otro dato como si
  // fuera el que se está tocando.
  useEffect(() => { setElegido(null); }, [grano, moneda]);

  const primero = cubos[0];
  const ultimo = cubos[cubos.length - 1];
  if (!primero || !ultimo) return null;

  const base = ALTO - ABAJO;
  const paso = ancho / cubos.length;
  const anchoBarra = Math.max(1, paso - HUECO);
  const alturaDe = (v: number) => (tope > 0 ? ((base - ARRIBA) * v) / tope : 0);
  let masAlta = primero;
  let iAlta = 0;
  cubos.forEach((c, i) => { if (c.valor > masAlta.valor) { masAlta = c; iAlta = i; } });

  // Un año agrupado por meses empieza y acaba en el mismo mes: sin el año,
  // los dos extremos del eje ponen «septiembre» y parece un error.
  const variosAnos = primero.desde.slice(0, 4) !== ultimo.desde.slice(0, 4);

  const fecha = (iso: string, largo = false) => {
    const como: Intl.DateTimeFormatOptions = { timeZone: 'UTC', month: largo ? 'long' : 'short' };
    if (grano !== 'mes') como.day = 'numeric';
    if (largo) como.year = 'numeric';
    else if (variosAnos) como.year = '2-digit';
    return new Date(`${iso}T00:00:00Z`).toLocaleDateString('es-ES', como);
  };

  // Al agrupar, el primer y el último tramo casi nunca están enteros: un año
  // por meses empieza a mitad de septiembre y acaba a mitad de septiembre. Si
  // se dibujaran como los demás, se leerían como dos meses flojos. Van
  // rayados, y el pie lo dice con palabras.
  const primerDia = dias[0]?.fecha ?? '';
  const ultimoDia = dias[dias.length - 1]?.fecha ?? '';
  const esParcial = (c: Cubo, i: number) => grano !== 'dia' && (
    (i === 0 && c.desde < primerDia) ||
    (i === cubos.length - 1 && finDeTramo(c.desde, grano) > ultimoDia));
  const hayParciales = cubos.some(esParcial);

  function tocar(e: React.PointerEvent<SVGSVGElement>) {
    const r = e.currentTarget.getBoundingClientRect();
    const i = Math.floor(((e.clientX - r.left) / r.width) * cubos.length);
    setElegido(i >= 0 && i < cubos.length ? i : null);
  }

  const sel = (elegido === null ? null : cubos[elegido]) ?? null;

  return (
    <div ref={caja}>
      {/* La lectura va en HTML, encima del dibujo: en un móvil un globito
          flotante se sale de la pantalla en la primera o la última barra. */}
      <div className="fila" style={{ minHeight: '1.4rem', marginBottom: '.35rem' }}>
        <span className="suave">
          {sel
            ? `${fecha(sel.desde, true)}${grano === 'dia' ? '' : ' →'} · ${sel.pedidos} pedido${sel.pedidos === 1 ? '' : 's'}${esParcial(sel, elegido ?? -1) ? ' · incompleto' : ''}`
            : `Ventas ${GRANOS[grano]}${hayParciales ? ' · extremos incompletos' : ''}`}
        </span>
        {sel && <strong style={{ fontVariantNumeric: 'tabular-nums' }}>{formato(sel.valor)}</strong>}
      </div>

      <svg
        width={ancho} height={ALTO} role="img"
        aria-label={`Ventas ${GRANOS[grano]} del periodo`}
        style={{ display: 'block', touchAction: 'pan-y' }}
        onPointerMove={tocar}
        onPointerDown={tocar}
        onPointerLeave={() => setElegido(null)}
      >
        <defs>
          {/* Rayado, no un color más claro: un tono distinto se confundiría
              con la barra apagada al pasar por encima, y además el dato no
              puede quedar cifrado solo en el color. */}
          <pattern id="tramo-incompleto" width="6" height="6" patternUnits="userSpaceOnUse">
            <rect width="6" height="6" fill="var(--marca)" />
            <path d="M-1,1 l2,-2 M0,6 l6,-6 M5,7 l2,-2"
                  stroke="var(--superficie)" strokeWidth="1.6" />
          </pattern>
        </defs>

        {cubos.map((c, i) => {
          const alto = alturaDe(c.valor);
          const parcial = esParcial(c, i);
          const x = i * paso + HUECO / 2;
          const y = base - alto;
          const activa = elegido === i;
          return (
            <g key={c.desde}>
              {/* Tira invisible de alto completo: el blanco al que se apunta
                  es más ancho que la barra, y en las barras bajas o a cero
                  sigue habiendo algo que tocar. */}
              <rect x={i * paso} y={0} width={paso} height={base} fill="transparent" />
              {alto > 0 && (
                <path
                  d={barra(x, y, anchoBarra, base)}
                  fill={parcial ? 'url(#tramo-incompleto)' : 'var(--marca)'}
                  opacity={elegido === null || activa ? 1 : 0.38}
                />
              )}
              <title>
                {`${fecha(c.desde, true)}: ${formato(c.valor)}, ${c.pedidos} pedidos`}
                {parcial ? ' (tramo incompleto)' : ''}
              </title>
            </g>
          );
        })}

        {/* Sin eje de valores: la cifra de la barra más alta es la referencia
            de escala, y así no hay una rejilla compitiendo con los datos. */}
        {tope > 0 && elegido === null && (
          <text
            x={Math.min(ancho - 2, Math.max(0, iAlta * paso + anchoBarra / 2))}
            y={base - alturaDe(masAlta.valor) - 6}
            textAnchor={iAlta > cubos.length - 3 ? 'end' : iAlta < 2 ? 'start' : 'middle'}
            fontSize="11" fontWeight="600" fill="var(--texto)"
            style={{ fontVariantNumeric: 'tabular-nums' }}
          >
            {formato(masAlta.valor)}
          </text>
        )}

        <line x1={0} y1={base} x2={ancho} y2={base} stroke="var(--borde)" strokeWidth={1} />

        <text x={0} y={ALTO - 5} fontSize="10.5" fill="var(--suave)">
          {fecha(primero.desde)}
        </text>
        <text x={ancho} y={ALTO - 5} fontSize="10.5" fill="var(--suave)" textAnchor="end">
          {fecha(ultimo.desde)}
        </text>
      </svg>
    </div>
  );
}
