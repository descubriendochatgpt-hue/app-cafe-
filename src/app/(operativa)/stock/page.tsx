'use client';

/**
 * Existencias. Se pinta desde la copia local, así que funciona sin cobertura
 * y abre al instante; si hay red, se refresca sola por detrás.
 */
import { useMemo, useState } from 'react';
import { useApp } from '@/componentes/Estado';

export default function Stock() {
  const { catalogo, cargando } = useApp();
  const [filtro, setFiltro] = useState<'TODO' | 'BAJO' | 'VIEJO'>('TODO');
  const [busca, setBusca] = useState('');

  const filas = useMemo(() => {
    if (!catalogo) return [];

    const porLote = new Map(catalogo.lotes.map((l) => [l.lote_id, l]));
    const agrupado = new Map<string, {
      sku: string; cafe: string; formato: string | null; unidad: string;
      total: number; porUbicacion: Map<string, number>;
      peorFrescura: string; diasMax: number | null; minimo: number | null;
    }>();

    for (const s of catalogo.saldos) {
      const lote = porLote.get(s.lote_id);
      if (!lote) continue;

      const clave = s.sku;
      let fila = agrupado.get(clave);
      if (!fila) {
        fila = {
          sku: s.sku, cafe: lote.cafe, formato: lote.formato, unidad: lote.unidad,
          total: 0, porUbicacion: new Map(), peorFrescura: 'FRESCO', diasMax: null,
          minimo: catalogo.precios.find((p) => p.sku === s.sku)?.stock_minimo ?? null,
        };
        agrupado.set(clave, fila);
      }

      fila.total += Number(s.cantidad);
      fila.porUbicacion.set(s.ubicacion, (fila.porUbicacion.get(s.ubicacion) ?? 0) + Number(s.cantidad));

      const orden = ['FRESCO', 'SIN_FECHA', 'AVISO', 'CRITICO'];
      if (orden.indexOf(lote.frescura) > orden.indexOf(fila.peorFrescura)) {
        fila.peorFrescura = lote.frescura;
      }
      if (lote.dias_desde_tueste !== null) {
        fila.diasMax = Math.max(fila.diasMax ?? 0, lote.dias_desde_tueste);
      }
    }

    return [...agrupado.values()]
      .filter((f) => {
        if (busca && !`${f.cafe} ${f.formato ?? ''} ${f.sku}`.toLowerCase().includes(busca.toLowerCase())) {
          return false;
        }
        if (filtro === 'BAJO') return f.minimo !== null && f.total <= f.minimo;
        if (filtro === 'VIEJO') return f.peorFrescura === 'AVISO' || f.peorFrescura === 'CRITICO';
        return true;
      })
      .sort((a, b) => a.cafe.localeCompare(b.cafe, 'es'));
  }, [catalogo, filtro, busca]);

  if (cargando && !catalogo) return <main><p className="suave">Cargando…</p></main>;

  return (
    <main>
      <h1>Stock</h1>
      <p className="sub">
        Sumado del libro de movimientos. Si un número no cuadra, se puede ver qué lo produjo.
      </p>

      <div className="chips">
        {([['TODO', 'Todo'], ['BAJO', 'Bajo mínimo'], ['VIEJO', 'Envejeciendo']] as const).map(
          ([id, texto]) => (
            <button key={id} className={filtro === id ? 'on' : ''} onClick={() => setFiltro(id)}>
              {texto}
            </button>
          ),
        )}
      </div>

      <input
        value={busca} onChange={(e) => setBusca(e.target.value)}
        placeholder="Buscar café o formato" style={{ marginBottom: '1rem' }}
      />

      {filas.length === 0 && (
        <div className="aviso info">
          {catalogo ? 'Nada que mostrar con este filtro.' : 'Sin datos descargados todavía.'}
        </div>
      )}

      {filas.map((f) => (
        <div key={f.sku} className="tarjeta">
          <div className="fila">
            <strong>{f.cafe}</strong>
            <strong>{f.total} {f.unidad === 'KG' ? 'kg' : ''}</strong>
          </div>
          <div className="fila">
            <span className="suave">{f.formato ?? 'café verde'}</span>
            <span>
              {f.minimo !== null && f.total <= f.minimo && (
                <span className="etiqueta CRITICO" style={{ marginRight: '.35rem' }}>
                  bajo mínimo
                </span>
              )}
              {f.peorFrescura !== 'FRESCO' && f.peorFrescura !== 'SIN_FECHA' && (
                <span className={`etiqueta ${f.peorFrescura}`}>
                  {f.diasMax} días
                </span>
              )}
            </span>
          </div>
          <table style={{ marginTop: '.55rem' }}>
            <tbody>
              {[...f.porUbicacion.entries()].map(([ubicacion, cantidad]) => (
                <tr key={ubicacion}>
                  <td className="suave">{ubicacion}</td>
                  <td className="num">{cantidad}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ))}
    </main>
  );
}
