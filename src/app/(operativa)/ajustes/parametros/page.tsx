'use client';

/**
 * Parámetros de funcionamiento.
 *
 * Todo lo configurable vive aquí y no en el código: umbrales de frescura,
 * días de consumo preferente, prefijo de GS1, mensajes de hostelería.
 * Cambiar uno no es un despliegue.
 */
import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';

interface Parametro { clave: string; valor: string; descripcion: string }

const GRUPOS: { titulo: string; prefijos: string[] }[] = [
  { titulo: 'Frescura y stock', prefijos: ['dias_frescura', 'dias_cobertura', 'dias_venta', 'dias_consumo'] },
  { titulo: 'Tueste', prefijos: ['merma_'] },
  { titulo: 'Ventas', prefijos: ['iva_'] },
  { titulo: 'Depósito', prefijos: ['dias_antiguedad'] },
  { titulo: 'Etiquetas y códigos', prefijos: ['nombre_empresa', 'texto_legal', 'prefijo_gs1', 'ean_'] },
  { titulo: 'Hostelería', prefijos: ['hosteleria_'] },
  { titulo: 'Acceso', prefijos: ['acceso_'] },
  { titulo: 'Conectores', prefijos: ['loyverse_'] },
];

export default function Parametros() {
  const [filas, setFilas] = useState<Parametro[]>([]);
  const [borrador, setBorrador] = useState<Record<string, string>>({});
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    const r = await fetch('/api/admin/parametros');
    if (!r.ok) {
      const d = await r.json() as { error?: string };
      setError(d.error ?? 'No se pudo cargar.');
      setCargando(false);
      return;
    }
    const d = await r.json() as { filas: Parametro[] };
    setFilas(d.filas);
    setBorrador(Object.fromEntries(d.filas.map((p) => [p.clave, p.valor])));
    setCargando(false);
  }, []);

  useEffect(() => { void cargar(); }, [cargar]);

  async function guardar(clave: string) {
    setGuardando(clave);
    setError(null);
    try {
      const r = await fetch('/api/admin/parametros', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ clave, valor: borrador[clave] ?? '' }),
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

  if (cargando) return <main><p className="suave">Cargando…</p></main>;

  const usados = new Set<string>();
  const grupos = GRUPOS.map((g) => {
    const suyos = filas.filter((p) => g.prefijos.some((pre) => p.clave.startsWith(pre)));
    suyos.forEach((p) => usados.add(p.clave));
    return { ...g, filas: suyos };
  }).filter((g) => g.filas.length > 0);
  const resto = filas.filter((p) => !usados.has(p.clave));

  return (
    <main>
      <h1>Parámetros</h1>
      <p className="sub">
        Cambiar cualquiera de estos tiene efecto en el acto. No hay que volver a desplegar.
      </p>

      {error && <div className="aviso error">{error}</div>}

      {[...grupos, ...(resto.length ? [{ titulo: 'Otros', filas: resto }] : [])].map((g) => (
        <section key={g.titulo}>
          <h2>{g.titulo}</h2>
          {g.filas.map((p) => (
            <div key={p.clave} className="tarjeta">
              <div className="mono" style={{ marginBottom: '.2rem' }}>{p.clave}</div>
              <p className="suave" style={{ margin: '0 0 .5rem' }}>{p.descripcion}</p>
              <div style={{ display: 'flex', gap: '.4rem' }}>
                <input
                  value={borrador[p.clave] ?? ''} style={{ marginTop: 0 }}
                  onChange={(e) => setBorrador({ ...borrador, [p.clave]: e.target.value })}
                />
                <button
                  style={{ flex: 'none' }}
                  disabled={guardando === p.clave || borrador[p.clave] === p.valor}
                  onClick={() => void guardar(p.clave)}
                >
                  {guardando === p.clave ? '…' : 'Guardar'}
                </button>
              </div>
            </div>
          ))}
        </section>
      ))}

      <p className="suave" style={{ marginTop: '1.5rem' }}>
        <Link href="/ajustes">← Ajustes</Link>
      </p>
    </main>
  );
}
