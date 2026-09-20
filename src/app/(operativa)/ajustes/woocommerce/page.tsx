'use client';

/**
 * Mapeo de productos de WooCommerce.
 *
 * Además de traducir «lo que vendió la web» a nuestras referencias, este
 * mapeo decide QUÉ SE PUBLICA: solo los productos emparejados reciben el
 * stock real. Un producto sin emparejar sigue con el stock que tuviera
 * puesto a mano en la tienda, que es exactamente como se vende algo que no
 * hay.
 */
import { useEffect, useMemo, useState } from 'react';
import Link from 'next/link';

interface Producto {
  codigo: string; nombre: string; sku_woo: string | null;
  tipo: 'simple' | 'variacion'; padre: number | null;
}
interface Interno { sku: string }

export default function MapeoWoo() {
  const [productos, setProductos] = useState<Producto[]>([]);
  const [mapeo, setMapeo] = useState<Record<string, string>>({});
  const [internos, setInternos] = useState<Interno[]>([]);
  const [ubicacion, setUbicacion] = useState('');
  const [colchon, setColchon] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState<string | null>(null);
  const [publicando, setPublicando] = useState(false);
  const [aviso, setAviso] = useState<string | null>(null);
  const [soloSinMapear, setSoloSinMapear] = useState(false);

  useEffect(() => {
    void (async () => {
      try {
        const r = await fetch('/api/woocommerce/productos');
        const d = await r.json() as {
          error?: string; productos?: Producto[];
          mapeo?: { codigo_externo: string; sku: string }[]; internos?: Interno[];
          ubicacion?: string; colchon?: number;
        };
        if (!r.ok) { setError(d.error ?? 'No se pudo cargar.'); return; }
        setProductos(d.productos ?? []);
        setInternos(d.internos ?? []);
        setUbicacion(d.ubicacion ?? '');
        setColchon(d.colchon ?? 0);
        setMapeo(Object.fromEntries((d.mapeo ?? []).map((m) => [m.codigo_externo, m.sku])));
      } finally {
        setCargando(false);
      }
    })();
  }, []);

  async function guardar(p: Producto, sku: string) {
    setGuardando(p.codigo);
    try {
      const r = await fetch('/api/mapeo', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          canal: 'woocommerce', codigoExterno: p.codigo,
          sku: sku || null, descripcion: p.nombre,
          datos: { tipo: p.tipo, padre: p.padre },
        }),
      });
      if (!r.ok) {
        const d = await r.json() as { error?: string };
        setError(d.error ?? 'No se pudo guardar el mapeo.');
        return;
      }
      setMapeo((m) => {
        const copia = { ...m };
        if (sku) copia[p.codigo] = sku; else delete copia[p.codigo];
        return copia;
      });
      setError(null);
    } finally {
      setGuardando(null);
    }
  }

  async function publicarAhora() {
    setPublicando(true);
    setAviso(null);
    try {
      const r = await fetch('/api/cron/woocommerce');
      const d = await r.json() as { error?: string; cambios?: number; nota?: string };
      setAviso(r.ok
        ? (d.nota ?? `Publicadas ${d.cambios ?? 0} referencias en la tienda.`)
        : (d.error ?? 'No se pudo publicar.'));
    } finally {
      setPublicando(false);
    }
  }

  const visibles = useMemo(
    () => (soloSinMapear ? productos.filter((p) => !mapeo[p.codigo]) : productos),
    [productos, mapeo, soloSinMapear],
  );
  const sinMapear = productos.filter((p) => !mapeo[p.codigo]).length;

  if (cargando) return <main><p className="suave">Consultando WooCommerce…</p></main>;

  return (
    <main>
      <h1>Productos de WooCommerce</h1>
      <p className="sub">
        Solo los productos emparejados reciben el stock real. Los que queden sueltos
        seguirán con el número que tengan puesto a mano en la tienda.
      </p>

      {error && <div className="aviso error">{error}</div>}
      {aviso && <div className="aviso ok">{aviso}</div>}

      {productos.length > 0 && (
        <div className={`aviso ${sinMapear > 0 ? 'error' : 'ok'}`}>
          {sinMapear === 0
            ? `Los ${productos.length} productos están emparejados.`
            : `${sinMapear} de ${productos.length} productos sin emparejar.`}
        </div>
      )}

      <div className="tarjeta">
        <div className="fila">
          <span>Se publica el stock de</span>
          <strong>{ubicacion}</strong>
        </div>
        <div className="fila">
          <span>Colchón de seguridad</span>
          <strong>{colchon} {colchon === 1 ? 'paquete' : 'paquetes'}</strong>
        </div>
        <p className="suave" style={{ margin: '.5rem 0 0' }}>
          Se publica lo disponible —descontando lo ya comprometido por otros pedidos—
          menos el colchón. Se cambia en el fichero de integraciones.
        </p>
        <button
          className="secundario" style={{ marginTop: '.7rem' }}
          onClick={() => void publicarAhora()} disabled={publicando}
        >
          {publicando ? 'Publicando…' : 'Publicar stock ahora'}
        </button>
      </div>

      <div className="chips">
        <button className={soloSinMapear ? '' : 'on'} onClick={() => setSoloSinMapear(false)}>
          Todos
        </button>
        <button className={soloSinMapear ? 'on' : ''} onClick={() => setSoloSinMapear(true)}>
          Sin emparejar
        </button>
      </div>

      {visibles.map((p) => (
        <div key={p.codigo} className="tarjeta">
          <div className="fila">
            <strong>{p.nombre}</strong>
            {mapeo[p.codigo] && <span className="etiqueta FRESCO">emparejado</span>}
          </div>
          <div className="mono suave" style={{ marginBottom: '.4rem' }}>
            {p.tipo === 'variacion' ? `variación ${p.codigo} de ${p.padre}` : `producto ${p.codigo}`}
            {p.sku_woo ? ` · SKU ${p.sku_woo}` : ''}
          </div>
          <select
            value={mapeo[p.codigo] ?? ''}
            disabled={guardando === p.codigo}
            onChange={(e) => void guardar(p, e.target.value)}
          >
            <option value="">— sin emparejar —</option>
            {internos.map((i) => <option key={i.sku} value={i.sku}>{i.sku}</option>)}
          </select>
        </div>
      ))}

      {visibles.length === 0 && !error && (
        <div className="aviso info">
          {soloSinMapear ? 'No queda nada sin emparejar.' : 'WooCommerce no ha devuelto productos.'}
        </div>
      )}

      <p className="suave" style={{ marginTop: '1.5rem' }}>
        <Link href="/ajustes">← Ajustes</Link>
      </p>
    </main>
  );
}
