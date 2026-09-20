'use client';

/**
 * Enlaces de pedido para hostelería.
 *
 * Cada cliente tiene el suyo. Se genera, se manda una vez por WhatsApp y el
 * cliente lo guarda: a partir de ahí pide cuando quiera sin instalar nada ni
 * registrarse en ningún sitio.
 *
 * El enlace ES la credencial, así que quien lo tenga puede pedir en nombre de
 * ese cliente. Por eso se puede revocar de uno en uno, sin afectar al resto.
 */
import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { Copiable } from '@/componentes/Copiable';

interface Cliente {
  cliente_id: string; nombre: string; tipo: string; telefono: string | null;
  descuento_pct: number; token_creado_en: string | null; enlace: string | null;
}

export default function Hosteleria() {
  const [clientes, setClientes] = useState<Cliente[]>([]);
  const [cargando, setCargando] = useState(true);
  const [ocupado, setOcupado] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [soloHosteleria, setSolo] = useState(true);

  const cargar = useCallback(async () => {
    const r = await fetch('/api/clientes/enlace');
    if (!r.ok) {
      const d = await r.json() as { error?: string };
      setError(d.error ?? 'No se pudo cargar.');
      setCargando(false);
      return;
    }
    const d = await r.json() as { clientes: Cliente[] };
    setClientes(d.clientes);
    setCargando(false);
  }, []);

  useEffect(() => { void cargar(); }, [cargar]);

  async function actuar(clienteId: string, accion: 'generar' | 'revocar') {
    if (accion === 'revocar'
        && !confirm('El cliente dejará de poder pedir con su enlace actual. ¿Revocarlo?')) {
      return;
    }
    setOcupado(clienteId);
    setError(null);
    try {
      const r = await fetch('/api/clientes/enlace', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ clienteId, accion }),
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

  const visibles = soloHosteleria
    ? clientes.filter((c) => c.tipo.toLowerCase().startsWith('hostel'))
    : clientes;

  if (cargando) return <main><p className="suave">Cargando…</p></main>;

  return (
    <main>
      <h1>Pedidos de hostelería</h1>
      <p className="sub">
        Cada cliente tiene su enlace. Se manda una vez por WhatsApp y ya puede pedir
        cuando quiera, sin instalar nada.
      </p>

      {error && <div className="aviso error">{error}</div>}

      <div className="chips">
        <button className={soloHosteleria ? 'on' : ''} onClick={() => setSolo(true)}>
          Hostelería
        </button>
        <button className={soloHosteleria ? '' : 'on'} onClick={() => setSolo(false)}>
          Todos los clientes
        </button>
      </div>

      {visibles.length === 0 && (
        <div className="aviso info">
          {soloHosteleria
            ? 'No hay clientes con tipo «Hostelería». Cámbialo en la ficha del cliente o mira todos.'
            : 'No hay clientes dados de alta.'}
        </div>
      )}

      {visibles.map((c) => {
        const mensaje = c.enlace
          ? `Hola, ${c.nombre}. Aquí tienes tu enlace para hacer pedidos cuando quieras: ${c.enlace}`
          : '';
        const wa = c.telefono
          ? `https://wa.me/${c.telefono.replace(/\D/g, '')}?text=${encodeURIComponent(mensaje)}`
          : `https://wa.me/?text=${encodeURIComponent(mensaje)}`;

        return (
          <div key={c.cliente_id} className="tarjeta">
            <div className="fila">
              <strong>{c.nombre}</strong>
              {c.descuento_pct > 0 && (
                <span className="suave">{c.descuento_pct}% de descuento</span>
              )}
            </div>

            {c.enlace ? (
              <>
                <div style={{ margin: '.6rem 0 .4rem' }}><Copiable texto={c.enlace} /></div>
                <div className="suave" style={{ fontSize: '.78rem' }}>
                  Activo desde {new Date(c.token_creado_en!).toLocaleDateString('es-ES')}
                </div>
                <div style={{ display: 'flex', gap: '.5rem', marginTop: '.7rem' }}>
                  <a href={wa} target="_blank" rel="noreferrer" style={{ flex: 1 }}>
                    <button className="ancho" type="button">Mandar por WhatsApp</button>
                  </a>
                  <button
                    className="secundario" disabled={ocupado === c.cliente_id}
                    onClick={() => void actuar(c.cliente_id, 'revocar')}
                  >
                    Revocar
                  </button>
                </div>
                <p className="suave" style={{ margin: '.6rem 0 0', fontSize: '.78rem' }}>
                  Quien tenga este enlace puede pedir en nombre de {c.nombre}. Si se
                  filtra, revócalo y genera otro: el viejo deja de funcionar al momento.
                </p>
              </>
            ) : (
              <>
                <p className="suave" style={{ margin: '.4rem 0 .7rem' }}>
                  Todavía no tiene enlace.
                </p>
                <button
                  disabled={ocupado === c.cliente_id}
                  onClick={() => void actuar(c.cliente_id, 'generar')}
                >
                  {ocupado === c.cliente_id ? 'Generando…' : 'Generar enlace'}
                </button>
              </>
            )}
          </div>
        );
      })}

      <p className="suave" style={{ marginTop: '1.5rem' }}>
        <Link href="/ajustes">← Ajustes</Link>
      </p>
    </main>
  );
}
