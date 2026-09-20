'use client';

/**
 * Mapeo de artículos de Loyverse.
 *
 * Es la tabla que traduce «lo que vendió el TPV» a «qué SKU nuestro es». Se
 * mantiene a mano a propósito: con 20-30 referencias cuesta diez minutos, y
 * un emparejamiento automático por nombre se equivocaría en silencio entre
 * dos cafés parecidos, que es el error más caro de detectar.
 *
 * Un artículo sin mapear no se descarta: su venta espera en la cola hasta
 * que alguien lo mapee aquí, y entonces se reprocesa entera.
 */
import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';

interface Articulo { codigo: string; nombre: string; sku_loyverse: string | null }
interface Interno { sku: string; cafe_id: string; formato_id: string | null }

export default function MapeoLoyverse() {
  const [articulos, setArticulos] = useState<Articulo[]>([]);
  const [mapeo, setMapeo] = useState<Record<string, string>>({});
  const [internos, setInternos] = useState<Interno[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState<string | null>(null);
  const [soloSinMapear, setSoloSinMapear] = useState(false);

  useEffect(() => {
    void (async () => {
      try {
        const r = await fetch('/api/loyverse/articulos');
        const d = await r.json() as {
          error?: string; articulos?: Articulo[];
          mapeo?: { codigo_externo: string; sku: string }[]; internos?: Interno[];
        };
        if (!r.ok) { setError(d.error ?? 'No se pudo cargar.'); return; }
        setArticulos(d.articulos ?? []);
        setInternos(d.internos ?? []);
        setMapeo(Object.fromEntries((d.mapeo ?? []).map((m) => [m.codigo_externo, m.sku])));
      } finally {
        setCargando(false);
      }
    })();
  }, []);

  async function guardar(codigo: string, sku: string, nombre: string) {
    setGuardando(codigo);
    try {
      const r = await fetch('/api/mapeo', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          canal: 'loyverse', codigoExterno: codigo,
          sku: sku || null, descripcion: nombre,
        }),
      });
      if (!r.ok) {
        const d = await r.json() as { error?: string };
        setError(d.error ?? 'No se pudo guardar el mapeo.');
        return;
      }
      setMapeo((m) => {
        const copia = { ...m };
        if (sku) copia[codigo] = sku; else delete copia[codigo];
        return copia;
      });
      setError(null);
    } finally {
      setGuardando(null);
    }
  }

  const visibles = useMemo(
    () => (soloSinMapear ? articulos.filter((a) => !mapeo[a.codigo]) : articulos),
    [articulos, mapeo, soloSinMapear],
  );
  const sinMapear = articulos.filter((a) => !mapeo[a.codigo]).length;

  if (cargando) return <main><p className="suave">Consultando Loyverse…</p></main>;

  return (
    <main>
      <h1>Artículos de Loyverse</h1>
      <p className="sub">
        Empareja cada artículo del TPV con su referencia interna. Lo que quede sin
        emparejar deja su venta esperando en la cola, no la pierde.
      </p>

      {error && <div className="aviso error">{error}</div>}

      {articulos.length > 0 && (
        <div className={`aviso ${sinMapear > 0 ? 'error' : 'ok'}`}>
          {sinMapear === 0
            ? `Los ${articulos.length} artículos están emparejados.`
            : `${sinMapear} de ${articulos.length} artículos sin emparejar.`}
        </div>
      )}

      <div className="chips">
        <button className={soloSinMapear ? '' : 'on'} onClick={() => setSoloSinMapear(false)}>
          Todos
        </button>
        <button className={soloSinMapear ? 'on' : ''} onClick={() => setSoloSinMapear(true)}>
          Sin emparejar
        </button>
      </div>

      {visibles.map((a) => (
        <div key={a.codigo} className="tarjeta">
          <div className="fila">
            <strong>{a.nombre}</strong>
            {mapeo[a.codigo] && <span className="etiqueta FRESCO">emparejado</span>}
          </div>
          {a.sku_loyverse && (
            <div className="mono suave" style={{ marginBottom: '.4rem' }}>
              SKU en Loyverse: {a.sku_loyverse}
            </div>
          )}
          <select
            value={mapeo[a.codigo] ?? ''}
            disabled={guardando === a.codigo}
            onChange={(e) => void guardar(a.codigo, e.target.value, a.nombre)}
          >
            <option value="">— sin emparejar —</option>
            {internos.map((i) => (
              <option key={i.sku} value={i.sku}>{i.sku}</option>
            ))}
          </select>
        </div>
      ))}

      {visibles.length === 0 && !error && (
        <div className="aviso info">
          {soloSinMapear ? 'No queda nada sin emparejar.' : 'Loyverse no ha devuelto artículos.'}
        </div>
      )}

      <p className="suave" style={{ marginTop: '1.5rem' }}>
        <Link href="/ajustes">← Ajustes</Link>
      </p>
    </main>
  );
}
