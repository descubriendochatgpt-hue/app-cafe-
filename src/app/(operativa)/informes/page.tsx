'use client';

/**
 * Informes. Todo se deriva del libro de movimientos; nada de esto se guarda.
 */
import { useCallback, useEffect, useState } from 'react';

interface Deposito {
  ubicacion_id: string; sku: string; lote_id: string;
  servido: number; vendido: number; devuelto: number; saldo: number;
  descuadre: number; dias_en_deposito: number | null; envejecido: boolean;
}
interface Frescura {
  lote_id: string; sku: string; ubicacion_id: string; cantidad: number;
  fecha_tostado: string; dias_desde_tueste: number; frescura: string;
}
interface Lote {
  lote_id: string; cafe: string; formato: string | null;
  fecha_tostado: string | null; stock_total: number;
}
interface Traza {
  lote: string; nivel: number; lote_origen: string; sku_origen: string;
  proveedor: string | null; fecha_recepcion: string | null;
}

type Pestana = 'deposito' | 'frescura' | 'trazabilidad';

export default function Informes() {
  const [pestana, setPestana] = useState<Pestana>('deposito');
  const [deposito, setDeposito] = useState<Deposito[]>([]);
  const [frescura, setFrescura] = useState<Frescura[]>([]);
  const [lotes, setLotes] = useState<Lote[]>([]);
  const [traza, setTraza] = useState<Traza[]>([]);
  const [lote, setLote] = useState('');
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    const r = await fetch('/api/informes');
    if (!r.ok) {
      const d = await r.json() as { error?: string };
      setError(d.error ?? 'No se pudo cargar.');
      setCargando(false);
      return;
    }
    const d = await r.json() as { deposito: Deposito[]; frescura: Frescura[]; lotes: Lote[] };
    setDeposito(d.deposito);
    setFrescura(d.frescura);
    setLotes(d.lotes);
    setCargando(false);
  }, []);

  useEffect(() => { void cargar(); }, [cargar]);

  async function verTraza(l: string) {
    setLote(l);
    setTraza([]);
    if (!l) return;
    const r = await fetch(`/api/informes?lote=${encodeURIComponent(l)}`);
    if (!r.ok) return;
    const d = await r.json() as { trazabilidad: Traza[] };
    setTraza(d.trazabilidad);
  }

  if (cargando) return <main><p className="suave">Cargando…</p></main>;

  const descuadres = deposito.filter((d) => Number(d.descuadre) !== 0);

  return (
    <main>
      <h1>Informes</h1>
      <p className="sub">Todo sale del libro de movimientos. Nada de esto se guarda aparte.</p>

      {error && <div className="aviso error">{error}</div>}

      <div className="chips">
        {([['deposito', 'Depósito'], ['frescura', 'Frescura'], ['trazabilidad', 'Trazabilidad']] as const)
          .map(([id, texto]) => (
            <button key={id} className={pestana === id ? 'on' : ''} onClick={() => setPestana(id)}>
              {texto}
            </button>
          ))}
      </div>

      {pestana === 'deposito' && (
        <>
          <p className="suave">
            Mercancía nuestra en casa ajena. Servir no es vender: la venta ocurre cuando
            el depositario reporta. <strong>Servido − vendido − devuelto = saldo</strong>, y
            el descuadre tiene que ser cero.
          </p>

          {descuadres.length > 0 && (
            <div className="aviso error">
              Hay {descuadres.length} lote(s) que no cuadran. Míralos en Conciliación.
            </div>
          )}

          {deposito.length === 0 && <div className="aviso info">No hay nada en depósito.</div>}

          {deposito.map((d) => (
            <div key={`${d.ubicacion_id}-${d.lote_id}`} className="tarjeta">
              <div className="fila">
                <strong className="mono">{d.sku}</strong>
                <strong>{Number(d.saldo)} en depósito</strong>
              </div>
              <div className="fila">
                <span className="suave">{d.ubicacion_id}</span>
                {d.envejecido && (
                  <span className="etiqueta CRITICO">{d.dias_en_deposito} días allí</span>
                )}
              </div>
              <table style={{ marginTop: '.5rem' }}>
                <tbody>
                  <tr><td className="suave">Servido</td><td className="num">{Number(d.servido)}</td></tr>
                  <tr><td className="suave">Reportado como vendido</td><td className="num">−{Number(d.vendido)}</td></tr>
                  <tr><td className="suave">Devuelto</td><td className="num">−{Number(d.devuelto)}</td></tr>
                  <tr>
                    <td><strong>Saldo</strong></td>
                    <td className="num"><strong>{Number(d.saldo)}</strong></td>
                  </tr>
                  {Number(d.descuadre) !== 0 && (
                    <tr>
                      <td style={{ color: 'var(--viejo)' }}>Descuadre</td>
                      <td className="num" style={{ color: 'var(--viejo)' }}>{Number(d.descuadre)}</td>
                    </tr>
                  )}
                </tbody>
              </table>
              <div className="mono suave" style={{ marginTop: '.4rem', fontSize: '.75rem' }}>
                {d.lote_id}
              </div>
            </div>
          ))}
        </>
      )}

      {pestana === 'frescura' && (
        <>
          <p className="suave">
            Lotes que pasan del umbral de aviso. Los umbrales se ajustan en Parámetros,
            al perfil de tueste de la casa.
          </p>
          {frescura.length === 0 && <div className="aviso ok">Todo lo que hay está fresco.</div>}
          {frescura.map((f) => (
            <div key={`${f.lote_id}-${f.ubicacion_id}`} className="tarjeta">
              <div className="fila">
                <strong className="mono">{f.sku}</strong>
                <span className={`etiqueta ${f.frescura}`}>{f.dias_desde_tueste} días</span>
              </div>
              <div className="fila">
                <span className="suave">{f.ubicacion_id} · tostado el {f.fecha_tostado}</span>
                <span>{Number(f.cantidad)} uds</span>
              </div>
              <div className="mono suave" style={{ marginTop: '.4rem', fontSize: '.75rem' }}>
                {f.lote_id}
              </div>
            </div>
          ))}
        </>
      )}

      {pestana === 'trazabilidad' && (
        <>
          <p className="suave">
            De una bolsa hacia atrás, hasta el saco de café verde del que salió.
          </p>
          <label>
            Lote
            <select value={lote} onChange={(e) => void verTraza(e.target.value)}>
              <option value="">Elige un lote…</option>
              {lotes.map((l) => (
                <option key={l.lote_id} value={l.lote_id}>
                  {l.cafe} · {l.formato} · {l.fecha_tostado}
                </option>
              ))}
            </select>
          </label>

          {lote && traza.length === 0 && (
            <div className="aviso info">
              Ese lote no tiene ascendencia registrada. Pasa con lo que se importó de las
              hojas: el saldo se migró, pero el tueste que lo produjo no.
            </div>
          )}

          {traza.map((t) => (
            <div key={t.lote_origen} className="tarjeta">
              <div className="fila">
                <strong>{t.proveedor ?? 'Origen'}</strong>
                <span className="suave">nivel {t.nivel}</span>
              </div>
              <div className="fila">
                <span className="mono suave">{t.lote_origen}</span>
                <span className="suave">{t.fecha_recepcion ?? ''}</span>
              </div>
            </div>
          ))}
        </>
      )}
    </main>
  );
}
