'use client';

/**
 * Editor de catálogo.
 *
 * Seis pantallas de mantenimiento con la misma forma: una lista, se pulsa una
 * fila y se edita. Escribirlas seis veces significaría corregir seis veces
 * cada detalle, así que se describen por campos y este componente las pinta.
 *
 * Lo que NO hace: validar. Eso lo hace el servidor y, por debajo, las
 * restricciones de la base. Aquí solo se muestra lo que responda, porque una
 * validación duplicada en el cliente acaba divergiendo de la de verdad.
 */
import { useCallback, useEffect, useState, type ReactNode } from 'react';
import { useApp } from './Estado';

export interface Campo {
  nombre: string;
  etiqueta: string;
  tipo: 'texto' | 'numero' | 'siNo' | 'lista' | 'area';
  opciones?: { valor: string; texto: string }[];
  ayuda?: string;
  /** La clave no se puede cambiar una vez creado el registro. */
  soloAlta?: boolean;
  requerido?: boolean;
  paso?: string;
}

export type Fila = Record<string, unknown>;

interface Props {
  recurso: string;
  campos: Campo[];
  clave: string;
  titulo: string;
  descripcion: string;
  /** Cómo se resume una fila en la lista. */
  resumen: (f: Fila) => ReactNode;
  /** Filtra lo que se lista, si la pantalla enseña solo una parte. */
  filtro?: (f: Fila) => boolean;
  /** Añadidos por fila: el botón de EAN, por ejemplo. */
  extra?: (f: Fila, recargar: () => Promise<void>) => ReactNode;
  vacia?: Fila;
}

export function Editor({
  recurso, campos, clave, titulo, descripcion, resumen, filtro, extra, vacia,
}: Props) {
  const [filas, setFilas] = useState<Fila[]>([]);
  const [editando, setEditando] = useState<Fila | null>(null);
  const [cargando, setCargando] = useState(true);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [campoMal, setCampoMal] = useState<Record<string, string>>({});
  const [busca, setBusca] = useState('');
  const { refrescar } = useApp();

  const cargar = useCallback(async () => {
    const r = await fetch(`/api/admin/${recurso}`);
    if (!r.ok) {
      const d = await r.json() as { error?: string };
      setError(d.error ?? 'No se pudo cargar.');
      setCargando(false);
      return;
    }
    const d = await r.json() as { filas: Fila[] };
    setFilas(d.filas);
    setError(null);
    setCargando(false);
  }, [recurso]);

  useEffect(() => { void cargar(); }, [cargar]);

  async function guardar(e: React.FormEvent) {
    e.preventDefault();
    if (!editando) return;
    setGuardando(true);
    setError(null);
    setCampoMal({});
    try {
      const r = await fetch(`/api/admin/${recurso}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(editando),
      });
      if (!r.ok) {
        const d = await r.json() as {
          error?: string; campos?: { campo: string; mensaje: string }[];
        };
        setError(d.error ?? 'No se pudo guardar.');
        if (d.campos) {
          setCampoMal(Object.fromEntries(d.campos.map((c) => [c.campo, c.mensaje])));
        }
        return;
      }
      setEditando(null);
      await cargar();

      // Y refrescar el catálogo compartido, no solo esta tabla.
      //
      // El resto de pantallas —Tueste, Escanear, Etiquetas— no consultan la
      // base cada vez: leen la copia local que permite trabajar sin cobertura
      // en un mercado. Esa copia se refresca sola cada minuto, así que sin
      // esto una referencia recién creada tarda en aparecer, y quien la acaba
      // de dar de alta en esta misma pantalla se queda pensando que no se ha
      // guardado. Dar de alta algo y no verlo es peor que esperar un segundo.
      await refrescar();
    } finally {
      setGuardando(false);
    }
  }

  const visibles = filas
    .filter((f) => !filtro || filtro(f))
    .filter((f) => !busca || JSON.stringify(f).toLowerCase().includes(busca.toLowerCase()));

  const esAlta = editando !== null && !filas.some((f) => f[clave] === editando[clave]);

  if (cargando) return <main><p className="suave">Cargando…</p></main>;

  return (
    <main>
      <h1>{titulo}</h1>
      <p className="sub">{descripcion}</p>

      {error && !editando && <div className="aviso error">{error}</div>}

      {editando ? (
        <form onSubmit={(e) => void guardar(e)} className="tarjeta">
          <h2 style={{ marginTop: 0 }}>{esAlta ? 'Nuevo' : String(editando[clave] ?? 'Editar')}</h2>
          {error && <div className="aviso error">{error}</div>}

          {campos.map((c) => {
            const valor = editando[c.nombre];
            const bloqueado = c.soloAlta && !esAlta;
            const mal = campoMal[c.nombre];

            return (
              <label key={c.nombre}>
                {c.etiqueta}
                {c.ayuda && <span className="suave"> · {c.ayuda}</span>}

                {c.tipo === 'siNo' ? (
                  <select
                    value={valor === false ? 'no' : 'si'}
                    onChange={(e) => setEditando({ ...editando, [c.nombre]: e.target.value === 'si' })}
                  >
                    <option value="si">Sí</option>
                    <option value="no">No</option>
                  </select>
                ) : c.tipo === 'lista' ? (
                  <select
                    value={String(valor ?? '')} required={c.requerido} disabled={bloqueado}
                    onChange={(e) => setEditando({ ...editando, [c.nombre]: e.target.value || null })}
                  >
                    <option value="">—</option>
                    {c.opciones?.map((o) => (
                      <option key={o.valor} value={o.valor}>{o.texto}</option>
                    ))}
                  </select>
                ) : c.tipo === 'area' ? (
                  <textarea
                    rows={2} value={String(valor ?? '')} disabled={bloqueado}
                    onChange={(e) => setEditando({ ...editando, [c.nombre]: e.target.value })}
                  />
                ) : (
                  <input
                    type={c.tipo === 'numero' ? 'number' : 'text'}
                    inputMode={c.tipo === 'numero' ? 'decimal' : undefined}
                    step={c.paso ?? (c.tipo === 'numero' ? 'any' : undefined)}
                    value={valor === null || valor === undefined ? '' : String(valor)}
                    required={c.requerido} disabled={bloqueado}
                    onChange={(e) => setEditando({
                      ...editando,
                      [c.nombre]: c.tipo === 'numero'
                        ? (e.target.value === '' ? null : Number(e.target.value))
                        : e.target.value,
                    })}
                  />
                )}
                {mal && <span style={{ color: 'var(--viejo)', fontSize: '.8rem' }}>{mal}</span>}
              </label>
            );
          })}

          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button style={{ flex: 1 }} disabled={guardando}>
              {guardando ? 'Guardando…' : 'Guardar'}
            </button>
            <button type="button" className="secundario"
                    onClick={() => { setEditando(null); setError(null); setCampoMal({}); }}>
              Cancelar
            </button>
          </div>
        </form>
      ) : (
        <>
          <div style={{ display: 'flex', gap: '.5rem', marginBottom: '1rem' }}>
            <input
              value={busca} onChange={(e) => setBusca(e.target.value)}
              placeholder="Buscar" style={{ marginTop: 0 }}
            />
            <button onClick={() => setEditando({ ...(vacia ?? {}) })} style={{ flex: 'none' }}>
              Nuevo
            </button>
          </div>

          {visibles.length === 0 && (
            <div className="aviso info">
              {filas.length === 0 ? 'Todavía no hay nada dado de alta.' : 'Nada con ese filtro.'}
            </div>
          )}

          {visibles.map((f) => (
            <div key={String(f[clave])} className="tarjeta">
              {resumen(f)}
              <div style={{ display: 'flex', gap: '.5rem', marginTop: '.7rem', flexWrap: 'wrap' }}>
                <button
                  className="secundario" style={{ padding: '.4rem .8rem', minHeight: 38 }}
                  onClick={() => setEditando({ ...f })}
                >
                  Editar
                </button>
                {extra?.(f, cargar)}
              </div>
            </div>
          ))}
        </>
      )}
    </main>
  );
}
