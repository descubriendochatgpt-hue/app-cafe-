'use client';

/**
 * Formulario de pedido para bares y cafeterías.
 *
 * Es la alternativa recomendada a interpretar mensajes de WhatsApp. «Ponme 3
 * de la mezcla» no dice el formato y «lo de siempre» no dice nada: un
 * desplegable no tiene ese problema.
 *
 * Lo abre gente que no ha instalado nada y que muchas veces está detrás de
 * una barra, así que: botones grandes, sin registro, sin contraseña, y el
 * total siempre a la vista.
 */
import { useEffect, useMemo, useState } from 'react';
import { nuevaOperacionId } from '@/lib/uuid';

interface Articulo {
  sku: string; cafe: string; origen: string | null; perfil_tueste: string | null;
  formato: string; gramos: number; molienda: string;
  precio: number; disponible: number;
}

interface Catalogo {
  cliente: { nombre: string; descuento_pct: number };
  articulos: Articulo[];
  mensaje_final: string;
  whatsapp: string;
}

interface Hecho { numero: string; cliente: string }

export function Formulario({ token }: { token: string }) {
  const [catalogo, setCatalogo] = useState<Catalogo | null>(null);
  const [cantidades, setCantidades] = useState<Record<string, number>>({});
  const [nota, setNota] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [cargando, setCargando] = useState(true);
  const [enviando, setEnviando] = useState(false);
  const [hecho, setHecho] = useState<Hecho | null>(null);

  // El identificador se fija al abrir la página, no al enviar: si el botón se
  // pulsa dos veces o la conexión se corta a mitad, el reenvío trae el mismo
  // y no se duplica el pedido.
  const [operacionId] = useState(() => nuevaOperacionId());

  useEffect(() => {
    void (async () => {
      try {
        const r = await fetch(`/api/pedido/${token}`);
        const d = await r.json() as Catalogo & { error?: string };
        if (!r.ok) { setError(d.error ?? 'No se pudo cargar el catálogo.'); return; }
        setCatalogo(d);
      } catch {
        setError('No hay conexión. Inténtalo dentro de un momento.');
      } finally {
        setCargando(false);
      }
    })();
  }, [token]);

  const lineas = useMemo(
    () => Object.entries(cantidades)
      .filter(([, n]) => n > 0)
      .map(([sku, cantidad]) => ({ sku, cantidad })),
    [cantidades],
  );

  const total = useMemo(() => {
    if (!catalogo) return 0;
    return lineas.reduce((s, l) => {
      const a = catalogo.articulos.find((x) => x.sku === l.sku);
      return s + (a?.precio ?? 0) * l.cantidad;
    }, 0);
  }, [lineas, catalogo]);

  function cambiar(sku: string, delta: number) {
    setCantidades((c) => {
      const nuevo = Math.max(0, Math.min(999, (c[sku] ?? 0) + delta));
      return { ...c, [sku]: nuevo };
    });
  }

  async function enviar() {
    setEnviando(true);
    setError(null);
    try {
      const r = await fetch(`/api/pedido/${token}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ operacionId, lineas, nota: nota || null }),
      });
      const d = await r.json() as { error?: string; numero?: string; cliente?: string };
      if (!r.ok) { setError(d.error ?? 'No se pudo enviar el pedido.'); return; }
      setHecho({ numero: d.numero ?? '', cliente: d.cliente ?? '' });
    } catch {
      setError('No se pudo enviar. Revisa la conexión y vuelve a intentarlo.');
    } finally {
      setEnviando(false);
    }
  }

  if (cargando) {
    return <main style={{ paddingTop: '3rem' }}><p className="suave">Cargando…</p></main>;
  }

  if (error && !catalogo) {
    return (
      <main style={{ paddingTop: '3rem' }}>
        <h1>Enlace no disponible</h1>
        <div className="aviso error">{error}</div>
      </main>
    );
  }

  if (hecho) {
    const aviso = catalogo?.whatsapp
      ? `https://wa.me/${catalogo.whatsapp}?text=${encodeURIComponent(
          `Hola, acabo de enviar el pedido ${hecho.numero}.`)}`
      : null;
    return (
      <main style={{ paddingTop: '3rem' }}>
        <h1>Pedido recibido</h1>
        <div className="aviso ok">
          <strong>{hecho.numero}</strong>
          <p style={{ margin: '.4rem 0 0' }}>{catalogo?.mensaje_final}</p>
        </div>
        <p className="suave">
          Apunta el número por si tienes que preguntar por él. Para hacer otro pedido,
          vuelve a abrir el mismo enlace.
        </p>
        {aviso && (
          <a href={aviso}><button className="ancho secundario" type="button">
            Avisar por WhatsApp
          </button></a>
        )}
      </main>
    );
  }

  return (
    <main style={{ paddingTop: '1.5rem' }}>
      <h1>Hacer pedido</h1>
      <p className="sub">
        {catalogo?.cliente.nombre}
        {(catalogo?.cliente.descuento_pct ?? 0) > 0
          && ` · precios con tu ${catalogo!.cliente.descuento_pct}% habitual`}
      </p>

      {error && <div className="aviso error">{error}</div>}

      {catalogo?.articulos.map((a) => {
        const n = cantidades[a.sku] ?? 0;
        return (
          <div key={a.sku} className="tarjeta">
            <div className="fila">
              <strong>{a.cafe}</strong>
              <strong>{a.precio.toFixed(2)} €</strong>
            </div>
            <div className="fila">
              <span className="suave">
                {a.formato}
                {a.origen ? ` · ${a.origen}` : ''}
              </span>
              {/* Se enseña lo que hay hoy, pero no se impide pedir más: para
                  eso está el tueste. Es información, no una barrera. */}
              {a.disponible <= 0 && <span className="etiqueta AVISO">se tuesta al pedido</span>}
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: '.6rem', marginTop: '.7rem' }}>
              <button
                type="button" className="secundario" aria-label={`Quitar ${a.cafe}`}
                style={{ width: 52, fontSize: '1.3rem', padding: 0 }}
                onClick={() => cambiar(a.sku, -1)} disabled={n === 0}
              >−</button>
              <span style={{
                minWidth: '2.5rem', textAlign: 'center',
                fontSize: '1.25rem', fontVariantNumeric: 'tabular-nums',
              }}>{n}</span>
              <button
                type="button" className="secundario" aria-label={`Añadir ${a.cafe}`}
                style={{ width: 52, fontSize: '1.3rem', padding: 0 }}
                onClick={() => cambiar(a.sku, 1)}
              >+</button>
              {n > 0 && (
                <span className="suave" style={{ marginLeft: 'auto' }}>
                  {(a.precio * n).toFixed(2)} €
                </span>
              )}
            </div>
          </div>
        );
      })}

      <label>
        ¿Algo que debamos saber? <span className="suave">(opcional)</span>
        <textarea
          rows={2} value={nota} maxLength={300}
          onChange={(e) => setNota(e.target.value)}
          placeholder="Para el jueves por la mañana, por ejemplo"
        />
      </label>

      <div
        style={{
          position: 'sticky', bottom: 0, background: 'var(--fondo)',
          padding: '.8rem 0 1.2rem', borderTop: '1px solid var(--borde)',
        }}
      >
        <div className="fila" style={{ marginBottom: '.6rem', fontSize: '1.15rem' }}>
          <strong>Total</strong>
          <strong>{total.toFixed(2)} €</strong>
        </div>
        <button
          className="ancho" onClick={() => void enviar()}
          disabled={enviando || lineas.length === 0}
        >
          {enviando ? 'Enviando…' : `Enviar pedido${lineas.length ? ` (${lineas.length})` : ''}`}
        </button>
        <p className="suave" style={{ margin: '.5rem 0 0', textAlign: 'center' }}>
          Impuestos no incluidos. Te confirmamos la entrega al preparar el pedido.
        </p>
      </div>
    </main>
  );
}
