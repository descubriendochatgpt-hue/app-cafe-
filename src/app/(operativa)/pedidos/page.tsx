'use client';

/**
 * Pedidos pendientes de salir.
 *
 * Aquí caen los de hostelería que llegaron por enlace y los de la web que
 * están pagados pero sin enviar. Todos tienen ya su stock RESERVADO: está
 * apartado, pero no ha salido del libro. Marcar «Servido» es lo que lo
 * descuenta de verdad.
 */
import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';

interface Linea { linea_id: string; sku: string; cantidad: number; servidas: number; importe?: number }
interface Pedido {
  pedido_id: string; numero: string; canal: string; estado: string; fecha: string;
  cliente: string | null; notas: string | null; total?: number; lineas: Linea[];
}

export default function Pedidos() {
  const [pedidos, setPedidos] = useState<Pedido[]>([]);
  const [conImportes, setConImportes] = useState(false);
  const [puedeCancelar, setPuedeCancelar] = useState(false);
  const [cargando, setCargando] = useState(true);
  const [ocupado, setOcupado] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    const r = await fetch('/api/pedidos');
    if (!r.ok) { setCargando(false); return; }
    const d = await r.json() as {
      pedidos: Pedido[]; conImportes: boolean; puedeCancelar: boolean;
    };
    setPedidos(d.pedidos);
    setConImportes(d.conImportes);
    setPuedeCancelar(d.puedeCancelar);
    setCargando(false);
  }, []);

  useEffect(() => { void cargar(); }, [cargar]);

  async function actuar(pedidoId: string, accion: 'servir' | 'cancelar') {
    if (accion === 'cancelar' && !confirm('¿Cancelar el pedido y soltar lo reservado?')) return;
    setOcupado(pedidoId);
    setError(null);
    try {
      const r = await fetch('/api/pedidos', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ accion, pedidoId }),
      });
      if (!r.ok) {
        const d = await r.json() as { error?: string };
        setError(d.error ?? 'No se pudo completar la acción.');
        return;
      }
      await cargar();
    } finally {
      setOcupado(null);
    }
  }

  if (cargando) return <main><p className="suave">Cargando…</p></main>;

  return (
    <main>
      <h1>Pedidos</h1>
      <p className="sub">
        Pendientes de salir. El stock ya está apartado; al marcar «Servido» se descuenta.
      </p>

      {error && <div className="aviso error">{error}</div>}
      {pedidos.length === 0 && <div className="aviso ok">No hay pedidos pendientes.</div>}

      {pedidos.map((p) => (
        <div key={p.pedido_id} className="tarjeta">
          <div className="fila">
            <strong>{p.cliente ?? 'Sin cliente'}</strong>
            <span className="etiqueta FRESCO">{p.canal}</span>
          </div>
          <div className="fila">
            <span className="mono suave">{p.numero}</span>
            <span className="suave">
              {new Date(`${p.fecha}T12:00:00`).toLocaleDateString('es-ES')}
            </span>
          </div>

          <table style={{ marginTop: '.6rem' }}>
            <tbody>
              {p.lineas.map((l) => (
                <tr key={l.linea_id}>
                  <td className="mono">{l.sku}</td>
                  <td className="num">{l.cantidad}</td>
                  {conImportes && <td className="num suave">{Number(l.importe ?? 0).toFixed(2)} €</td>}
                </tr>
              ))}
            </tbody>
          </table>

          {p.notas && (
            <div className="aviso info" style={{ margin: '.6rem 0 0' }}>{p.notas}</div>
          )}

          {conImportes && p.total !== undefined && (
            <div className="fila" style={{ marginTop: '.5rem' }}>
              <strong>Total</strong><strong>{Number(p.total).toFixed(2)} €</strong>
            </div>
          )}

          <div style={{ display: 'flex', gap: '.5rem', marginTop: '.8rem', flexWrap: 'wrap' }}>
            <Link href={`/pedidos/${p.pedido_id}`} style={{ flex: 1 }}>
              <button className="ancho" type="button">Preparar</button>
            </Link>
            <button
              className="secundario" disabled={ocupado === p.pedido_id}
              onClick={() => void actuar(p.pedido_id, 'servir')}
            >
              {ocupado === p.pedido_id ? 'Guardando…' : 'Servir todo'}
            </button>
            {puedeCancelar && (
              <button
                className="secundario" disabled={ocupado === p.pedido_id}
                onClick={() => void actuar(p.pedido_id, 'cancelar')}
              >
                Cancelar
              </button>
            )}
          </div>
        </div>
      ))}
    </main>
  );
}
