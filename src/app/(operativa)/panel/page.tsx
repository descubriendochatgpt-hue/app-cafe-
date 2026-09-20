'use client';

/**
 * El panel: cómo va el negocio de un vistazo.
 *
 * Todo lo que sale aquí lo calcula la función `panel()` en la base, y todo
 * se deriva del libro de movimientos y de los pedidos. No hay ni una cifra
 * guardada que pueda quedarse vieja, así que el panel no puede contradecir
 * al stock: son el mismo dato mirado desde dos sitios.
 *
 * Los importes tampoco los esconde esta pantalla: si quien mira no llega a
 * GESTOR, la base no los mete en la respuesta. Esta pantalla solo se adapta
 * a lo que le llega.
 */
import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { GraficoDiario, type Dia } from '@/componentes/Grafico';

interface Panel {
  dias: number;
  desde: string;
  con_importes: boolean;
  ventas: {
    pedidos: number; unidades: number;
    total: number | null; coste: number | null; margen: number | null;
    costes_completos: boolean; anterior: number | null;
  };
  por_dia: Dia[];
  por_canal: { canal: string; pedidos: number; total: number | null }[];
  top: { sku: string; unidades: number; importe: number | null }[];
  produccion: {
    tuestes: number; kg_verde: number; kg_tostado: number; merma_media: number | null;
  };
  stock: { unidades: number; kg_verde: number; valor: number | null; referencias: number };
  clientes: { nuevos: number; dormidos: number };
  avisos: {
    bajo_minimo: number | null; envejeciendo: number; incidencias: number;
    pedidos_pendientes: number; deposito_viejo: number;
  };
}

const PERIODOS = [[30, '30 días'], [90, '90 días'], [365, 'Un año']] as const;

const euros = new Intl.NumberFormat('es-ES', {
  style: 'currency', currency: 'EUR', maximumFractionDigits: 0,
});
const cifra = new Intl.NumberFormat('es-ES', { maximumFractionDigits: 0 });
const decimal = new Intl.NumberFormat('es-ES', { maximumFractionDigits: 1 });

const CANALES: Record<string, string> = {
  loyverse: 'TPV y mercados', woocommerce: 'Tienda web',
  eci: 'El Corte Inglés', hosteleria: 'Hostelería', app: 'Mostrador',
};

/** Una cifra grande con su rótulo. El dato manda; el rótulo acompaña. */
function Cifra({ valor, rotulo, nota }: { valor: string; rotulo: string; nota?: string }) {
  return (
    <div className="tarjeta" style={{ margin: 0 }}>
      <div style={{ fontSize: '1.5rem', fontWeight: 700, fontVariantNumeric: 'tabular-nums' }}>
        {valor}
      </div>
      <div className="suave" style={{ marginTop: '.15rem' }}>{rotulo}</div>
      {nota && <div className="suave" style={{ fontSize: '.75rem' }}>{nota}</div>}
    </div>
  );
}

export default function PanelPagina() {
  const [dias, setDias] = useState(30);
  const [datos, setDatos] = useState<Panel | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [cargando, setCargando] = useState(true);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    const r = await fetch(`/api/panel?dias=${dias}`);
    const d = await r.json() as Panel & { error?: string };
    if (!r.ok) setError(d.error ?? 'No se pudo cargar el panel.');
    else setDatos(d);
    setCargando(false);
  }, [dias]);

  useEffect(() => { void cargar(); }, [cargar]);

  const dinero = datos?.con_importes ?? false;
  const formato = (n: number) => (dinero ? euros.format(n) : `${cifra.format(n)} uds`);

  // Cuánto ha cambiado respecto al periodo anterior de la misma duración. Sin
  // periodo anterior con ventas no se enseña nada: un «+100 %» contra cero no
  // dice nada de cómo va el negocio.
  const anterior = Number(datos?.ventas.anterior ?? 0);
  const total = Number(datos?.ventas.total ?? 0);
  const variacion = anterior > 0 ? Math.round(((total - anterior) / anterior) * 100) : null;

  const avisos = datos?.avisos;
  const lista: [number, string, string][] = avisos ? ([
    [avisos.pedidos_pendientes, 'pedido(s) por preparar', '/pedidos'],
    [avisos.incidencias, 'incidencia(s) sin resolver', '/ajustes/conciliacion'],
    [avisos.envejeciendo, 'lote(s) pasados de frescura', '/informes'],
    [avisos.deposito_viejo, 'lote(s) llevan demasiado en depósito', '/informes'],
    [avisos.bajo_minimo ?? 0, 'referencia(s) bajo mínimos', '/stock'],
  ] as [number, string, string][]).filter(([n]) => n > 0) : [];

  return (
    <main>
      <h1>Panel</h1>
      <p className="sub">
        Todo sale del libro y de los pedidos, calculado en el momento. Se cuentan
        los pedidos servidos o entregados: uno confirmado todavía puede caerse.
      </p>

      <div className="chips">
        {PERIODOS.map(([d, texto]) => (
          <button key={d} className={dias === d ? 'on' : ''} onClick={() => setDias(d)}>
            {texto}
          </button>
        ))}
      </div>

      {error && <div className="aviso error">{error}</div>}
      {cargando && !datos && <p className="suave">Cargando…</p>}

      {datos && (
        <>
          {lista.length > 0 && (
            <div className="tarjeta" style={{ borderColor: 'var(--medio)' }}>
              <strong>Para mirar hoy</strong>
              {lista.map(([n, texto, href]) => (
                <div className="fila" key={href} style={{ marginTop: '.45rem' }}>
                  <Link href={href}>{texto.replace('(s)', n === 1 ? '' : 's')}</Link>
                  <strong>{n}</strong>
                </div>
              ))}
            </div>
          )}

          <h2>Ventas</h2>
          <div style={{
            display: 'grid', gap: '.6rem',
            gridTemplateColumns: 'repeat(auto-fit, minmax(9rem, 1fr))',
          }}>
            {dinero && (
              <Cifra
                valor={euros.format(total)}
                rotulo={`Facturado en ${datos.dias} días`}
                nota={variacion === null
                  ? 'sin periodo anterior con el que comparar'
                  : `${variacion >= 0 ? '+' : ''}${variacion} % frente a los ${datos.dias} días previos`}
              />
            )}
            <Cifra valor={cifra.format(datos.ventas.pedidos)} rotulo="Pedidos servidos" />
            <Cifra valor={cifra.format(Number(datos.ventas.unidades))} rotulo="Unidades" />
            {dinero && (
              <Cifra
                valor={euros.format(Number(datos.ventas.margen ?? 0))}
                rotulo="Margen bruto"
                nota={datos.ventas.costes_completos
                  ? `coste ${euros.format(Number(datos.ventas.coste ?? 0))}`
                  : 'faltan costes: la cifra sale alta de más'}
              />
            )}
          </div>

          {!datos.ventas.costes_completos && dinero && (
            <div className="aviso info" style={{ marginTop: '.6rem' }}>
              Hay artículos vendidos sin coste unitario en Precios. Mientras falten, el
              margen cuenta esas ventas como si no costaran nada. Se arregla en{' '}
              <Link href="/ajustes/catalogo">Catálogo</Link>.
            </div>
          )}

          <div className="tarjeta">
            <GraficoDiario dias={datos.por_dia} moneda={dinero} formato={formato} />
          </div>

          {datos.por_canal.length > 0 && (
            <>
              <h2>Por canal</h2>
              <table>
                <thead>
                  <tr>
                    <th>Canal</th>
                    <th className="num">Pedidos</th>
                    {dinero && <th className="num">Importe</th>}
                  </tr>
                </thead>
                <tbody>
                  {datos.por_canal.map((c) => (
                    <tr key={c.canal}>
                      <td>{CANALES[c.canal] ?? c.canal}</td>
                      <td className="num">{c.pedidos}</td>
                      {dinero && <td className="num">{euros.format(Number(c.total ?? 0))}</td>}
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}

          {datos.top.length > 0 && (
            <>
              <h2>Lo que más sale</h2>
              <table>
                <thead>
                  <tr>
                    <th>Referencia</th>
                    <th className="num">Unidades</th>
                    {dinero && <th className="num">Importe</th>}
                  </tr>
                </thead>
                <tbody>
                  {datos.top.map((t) => (
                    <tr key={t.sku}>
                      <td className="mono">{t.sku}</td>
                      <td className="num">{cifra.format(Number(t.unidades))}</td>
                      {dinero && <td className="num">{euros.format(Number(t.importe ?? 0))}</td>}
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}

          <h2>Producción</h2>
          <div className="tarjeta">
            <div className="fila">
              <span className="suave">Tuestes</span>
              <strong>{datos.produccion.tuestes}</strong>
            </div>
            <div className="fila">
              <span className="suave">Verde tostado</span>
              <span>{decimal.format(Number(datos.produccion.kg_verde))} kg</span>
            </div>
            <div className="fila">
              <span className="suave">Tostado obtenido</span>
              <span>{decimal.format(Number(datos.produccion.kg_tostado))} kg</span>
            </div>
            <div className="fila">
              <span className="suave">Merma media</span>
              <span>
                {datos.produccion.merma_media === null
                  ? '—'
                  : `${decimal.format(Number(datos.produccion.merma_media))} %`}
              </span>
            </div>
          </div>

          <h2>Hoy en almacén</h2>
          <div className="tarjeta">
            <div className="fila">
              <span className="suave">Paquetes</span>
              <strong>{cifra.format(Number(datos.stock.unidades))}</strong>
            </div>
            <div className="fila">
              <span className="suave">Café verde</span>
              <span>{decimal.format(Number(datos.stock.kg_verde))} kg</span>
            </div>
            <div className="fila">
              <span className="suave">Referencias con existencias</span>
              <span>{datos.stock.referencias}</span>
            </div>
            {dinero && (
              <div className="fila">
                <span className="suave">Valor a coste</span>
                <span>{euros.format(Number(datos.stock.valor ?? 0))}</span>
              </div>
            )}
          </div>

          <h2>Clientes</h2>
          <div className="tarjeta">
            <div className="fila">
              <span className="suave">Nuevos en el periodo</span>
              <strong>{datos.clientes.nuevos}</strong>
            </div>
            <div className="fila">
              <span className="suave">Dormidos</span>
              <span>{datos.clientes.dormidos}</span>
            </div>
            <p className="suave" style={{ margin: '.5rem 0 0', fontSize: '.8rem' }}>
              Dormido es un cliente que ya compró y lleva sin pedir más días de los
              que marca <Link href="/ajustes/parametros">Parámetros</Link>. Es la lista
              a la que merece la pena llamar.
            </p>
          </div>
        </>
      )}
    </main>
  );
}
