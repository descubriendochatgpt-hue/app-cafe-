'use client';

/**
 * Conciliación: todo lo que el sistema no ha sabido resolver solo.
 *
 * Es la contrapartida de no descartar nada en silencio. Si una venta llegó
 * con un artículo desconocido, si un webhook agotó sus reintentos o si la
 * proyección de saldos se aparta del libro, aparece aquí con lo necesario
 * para arreglarlo, en vez de manifestarse tres semanas después como un
 * inventario que no cuadra.
 */
import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';

interface Incidencia {
  incidencia_id: string; tipo: string; canal: string | null; referencia: string | null;
  detalle: Record<string, unknown>; creado_en: string;
}
interface Evento {
  evento_id: string; canal: string; tipo: string; origen_id: string;
  intentos: number; ultimo_error: string | null; recibido_en: string;
}
interface Descuadre {
  lote_id: string; ubicacion_id: string; segun_saldos: number;
  segun_libro: number; diferencia: number;
}

const EXPLICACION: Record<string, string> = {
  SKU_DESCONOCIDO: 'Un canal vendió algo que no está emparejado con ninguna referencia.',
  STOCK_INSUFICIENTE: 'Se vendió más de lo que decía haber. Conviene un recuento.',
  LOTE_SIN_RESOLVER: 'No se pudo decidir de qué lote salió la mercancía.',
  EVENTO_FALLIDO: 'Un evento agotó sus reintentos.',
  DESCUADRE_SALDO: 'La proyección de saldos no cuadra con el libro de movimientos.',
  DEPOSITO_PENDIENTE: 'Hay un informe de depósito sin cargar.',
};

export default function Conciliacion() {
  const [incidencias, setIncidencias] = useState<Incidencia[]>([]);
  const [eventos, setEventos] = useState<Evento[]>([]);
  const [descuadres, setDescuadres] = useState<Descuadre[]>([]);
  const [puedeResolver, setPuede] = useState(false);
  const [cargando, setCargando] = useState(true);
  const [ocupado, setOcupado] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    const r = await fetch('/api/conciliacion');
    if (!r.ok) { setCargando(false); return; }
    const d = await r.json() as {
      incidencias: Incidencia[]; eventos: Evento[];
      descuadres: Descuadre[]; puedeResolver: boolean;
    };
    setIncidencias(d.incidencias);
    setEventos(d.eventos);
    setDescuadres(d.descuadres);
    setPuede(d.puedeResolver);
    setCargando(false);
  }, []);

  useEffect(() => { void cargar(); }, [cargar]);

  async function actuar(cuerpo: unknown, id: string) {
    setOcupado(id);
    try {
      await fetch('/api/conciliacion', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(cuerpo),
      });
      await cargar();
    } finally {
      setOcupado(null);
    }
  }

  if (cargando) return <main><p className="suave">Cargando…</p></main>;

  const nada = incidencias.length === 0 && eventos.length === 0 && descuadres.length === 0;

  return (
    <main>
      <h1>Conciliación</h1>
      <p className="sub">Lo que necesita una decisión. Si está vacío, todo va solo.</p>

      {nada && <div className="aviso ok">Nada pendiente.</div>}

      {descuadres.length > 0 && (
        <>
          <h2>Descuadres de saldo</h2>
          <div className="aviso error">
            La proyección no cuadra con el libro. Esto no debería pasar nunca: manda el
            libro, y se corrige reconstruyendo los saldos desde él.
          </div>
          <table>
            <thead>
              <tr><th>Lote</th><th>Ubicación</th><th className="num">Saldo</th>
                  <th className="num">Libro</th><th className="num">Dif.</th></tr>
            </thead>
            <tbody>
              {descuadres.map((d) => (
                <tr key={`${d.lote_id}-${d.ubicacion_id}`}>
                  <td className="mono">{d.lote_id}</td>
                  <td>{d.ubicacion_id}</td>
                  <td className="num">{d.segun_saldos}</td>
                  <td className="num">{d.segun_libro}</td>
                  <td className="num">{d.diferencia}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}

      {eventos.length > 0 && (
        <>
          <h2>Eventos en cola</h2>
          {eventos.map((e) => (
            <div key={e.evento_id} className="tarjeta">
              <div className="fila">
                <strong>{e.canal} · {e.origen_id}</strong>
                <span className="suave">{e.intentos}/8 intentos</span>
              </div>
              <div className="aviso error" style={{ margin: '.5rem 0' }}>{e.ultimo_error}</div>
              <div className="suave">{new Date(e.recibido_en).toLocaleString('es-ES')}</div>
              {puedeResolver && (
                <button
                  className="secundario" style={{ marginTop: '.6rem', minHeight: 38, padding: '.4rem .8rem' }}
                  disabled={ocupado === e.evento_id}
                  onClick={() => void actuar({ accion: 'reintentar', eventoId: e.evento_id }, e.evento_id)}
                >
                  {ocupado === e.evento_id ? 'Reintentando…' : 'Reintentar ahora'}
                </button>
              )}
            </div>
          ))}
          <p className="suave">
            Si el motivo es un artículo sin emparejar, emparéjalo primero en{' '}
            <Link href="/ajustes/loyverse">artículos de Loyverse</Link> y después reintenta:
            la venta se reprocesa entera.
          </p>
        </>
      )}

      {incidencias.length > 0 && (
        <>
          <h2>Incidencias abiertas</h2>
          {incidencias.map((i) => (
            <div key={i.incidencia_id} className="tarjeta">
              <div className="fila">
                <strong>{i.tipo.replaceAll('_', ' ').toLowerCase()}</strong>
                <span className="suave">{new Date(i.creado_en).toLocaleString('es-ES')}</span>
              </div>
              <p className="suave" style={{ margin: '.3rem 0' }}>
                {EXPLICACION[i.tipo] ?? ''}
              </p>
              {i.referencia && <div className="mono suave">{i.canal} · {i.referencia}</div>}
              <pre className="mono suave" style={{
                margin: '.5rem 0 0', fontSize: '.72rem', whiteSpace: 'pre-wrap',
                background: 'var(--fondo)', padding: '.5rem', borderRadius: 6,
              }}>{JSON.stringify(i.detalle, null, 1)}</pre>
              {puedeResolver && (
                <button
                  className="secundario" style={{ marginTop: '.6rem', minHeight: 38, padding: '.4rem .8rem' }}
                  disabled={ocupado === i.incidencia_id}
                  onClick={() => void actuar(
                    { accion: 'resolver', incidenciaId: i.incidencia_id, resolucion: 'Revisada y corregida a mano' },
                    i.incidencia_id,
                  )}
                >
                  Dar por resuelta
                </button>
              )}
            </div>
          ))}
        </>
      )}

      <p className="suave" style={{ marginTop: '1.5rem' }}>
        <Link href="/ajustes">← Ajustes</Link>
      </p>
    </main>
  );
}
