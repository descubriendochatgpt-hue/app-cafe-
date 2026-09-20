'use client';

/**
 * Cuántos paquetes de cada formato caben en una caja.
 *
 * Es lo que permite proponer la caja más pequeña donde cabe un pedido, y
 * avisar antes de meter algo que no va a cerrar. Se mide una vez, metiendo
 * los paquetes de verdad.
 */
import { useCallback, useEffect, useState } from 'react';

interface Formato { formato_id: string; nombre: string; gramos: number }
interface Fila { caja_id: string; formato_id: string; unidades_max: number }

export function Capacidad({ cajaId }: { cajaId: string }) {
  const [formatos, setFormatos] = useState<Formato[]>([]);
  const [valores, setValores] = useState<Record<string, string>>({});
  const [guardando, setGuardando] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    const r = await fetch('/api/admin/capacidad');
    if (!r.ok) return;
    const d = await r.json() as { capacidad: Fila[]; formatos: Formato[] };
    setFormatos(d.formatos);
    setValores(Object.fromEntries(
      d.capacidad.filter((c) => c.caja_id === cajaId)
        .map((c) => [c.formato_id, String(c.unidades_max)]),
    ));
  }, [cajaId]);

  useEffect(() => { void cargar(); }, [cargar]);

  async function guardar(formatoId: string, valor: string) {
    setGuardando(formatoId);
    setError(null);
    try {
      const r = await fetch('/api/admin/capacidad', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          cajaId, formatoId, unidadesMax: valor === '' ? null : Number(valor),
        }),
      });
      if (!r.ok) {
        const d = await r.json() as { error?: string };
        setError(d.error ?? 'No se pudo guardar.');
        return;
      }
      await cargar();
    } finally {
      setGuardando(null);
    }
  }

  if (formatos.length === 0) return null;

  return (
    <div style={{ width: '100%', marginTop: '.6rem' }}>
      <div className="suave" style={{ marginBottom: '.35rem' }}>Cuántos caben:</div>
      {error && <div className="aviso error">{error}</div>}
      <table>
        <tbody>
          {formatos.map((f) => (
            <tr key={f.formato_id}>
              <td>{f.nombre}</td>
              <td style={{ width: '6.5rem' }}>
                <input
                  type="number" min="0" inputMode="numeric" placeholder="—"
                  style={{ marginTop: 0, padding: '.35rem .5rem', textAlign: 'right' }}
                  value={valores[f.formato_id] ?? ''}
                  disabled={guardando === f.formato_id}
                  onChange={(e) => setValores({ ...valores, [f.formato_id]: e.target.value })}
                  onBlur={(e) => void guardar(f.formato_id, e.target.value)}
                />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="suave" style={{ margin: '.3rem 0 0', fontSize: '.75rem' }}>
        Déjalo vacío si esa caja no se usa para ese formato.
      </p>
    </div>
  );
}
