'use client';

/**
 * Bot de consulta.
 *
 * Dos cosas en una pantalla: darse de alta (para preguntar desde Instagram
 * sin abrir la app) y probar las respuestas aquí mismo, que funciona desde el
 * primer día sin esperar a la aprobación de Meta.
 */
import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';

interface Autorizado {
  canal: string; id_externo: string; usuario_id: string;
  nombre?: string; alias: string | null; creado_en: string; ultimo_uso: string | null;
}

const EJEMPLOS = ['ayuda', 'stock', 'mínimos', 'pedidos', 'depósito', 'frescura', 'verde'];

export default function Bot() {
  const [autorizados, setAutorizados] = useState<Autorizado[]>([]);
  const [esAdmin, setEsAdmin] = useState(false);
  const [yo, setYo] = useState('');
  const [codigo, setCodigo] = useState<{ codigo: string; minutos: number } | null>(null);
  const [pregunta, setPregunta] = useState('');
  const [respuesta, setRespuesta] = useState<string | null>(null);
  const [ocupado, setOcupado] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    const r = await fetch('/api/admin/bot');
    if (!r.ok) return;
    const d = await r.json() as { autorizados: Autorizado[]; esAdmin: boolean; yo: string };
    setAutorizados(d.autorizados);
    setEsAdmin(d.esAdmin);
    setYo(d.yo);
  }, []);

  useEffect(() => { void cargar(); }, [cargar]);

  async function pedirCodigo() {
    setOcupado(true);
    setError(null);
    try {
      const r = await fetch('/api/admin/bot', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ accion: 'codigo' }),
      });
      const d = await r.json() as { error?: string; codigo?: string; minutos?: number };
      if (!r.ok || !d.codigo) { setError(d.error ?? 'No se pudo generar.'); return; }
      setCodigo({ codigo: d.codigo, minutos: d.minutos ?? 15 });
    } finally {
      setOcupado(false);
    }
  }

  async function preguntar(texto: string) {
    setOcupado(true);
    setRespuesta(null);
    setError(null);
    try {
      const r = await fetch('/api/consulta', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pregunta: texto }),
      });
      const d = await r.json() as { error?: string; respuesta?: string };
      if (!r.ok) { setError(d.error ?? 'No se pudo responder.'); return; }
      setRespuesta(d.respuesta ?? '');
    } finally {
      setOcupado(false);
    }
  }

  async function revocar(a: Autorizado) {
    if (!confirm(`¿Quitarle el acceso al bot a ${a.nombre ?? a.alias ?? a.id_externo}?`)) return;
    await fetch('/api/admin/bot', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ accion: 'revocar', canal: a.canal, idExterno: a.id_externo }),
    });
    await cargar();
  }

  const mio = autorizados.find((a) => a.usuario_id === yo);

  return (
    <main>
      <h1>Bot de consulta</h1>
      <p className="sub">
        Preguntar por el negocio desde el móvil sin abrir la app.
      </p>

      {error && <div className="aviso error">{error}</div>}

      <h2>Probar aquí</h2>
      <p className="suave">
        Las mismas respuestas que da por Instagram, con tu perfil. Funciona desde ya,
        sin esperar a Meta.
      </p>

      <div style={{ display: 'flex', gap: '.4rem' }}>
        <input
          value={pregunta} placeholder="stock etiopía" style={{ marginTop: 0 }}
          onChange={(e) => setPregunta(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && pregunta) void preguntar(pregunta); }}
        />
        <button style={{ flex: 'none' }} disabled={ocupado || !pregunta}
                onClick={() => void preguntar(pregunta)}>
          Preguntar
        </button>
      </div>

      <div className="chips" style={{ marginTop: '.6rem' }}>
        {EJEMPLOS.map((e) => (
          <button key={e} onClick={() => { setPregunta(e); void preguntar(e); }}>{e}</button>
        ))}
      </div>

      {respuesta !== null && (
        <pre className="tarjeta" style={{
          whiteSpace: 'pre-wrap', fontFamily: 'inherit', fontSize: '.9rem', margin: 0,
        }}>{respuesta}</pre>
      )}

      <h2>Tu acceso desde Instagram</h2>
      {mio ? (
        <div className="tarjeta">
          <div className="fila">
            <strong>Dado de alta</strong>
            <span className="etiqueta FRESCO">activo</span>
          </div>
          <p className="suave" style={{ margin: '.4rem 0 0' }}>
            Escríbele por mensaje directo a la cuenta de la casa y te responde.
            {mio.ultimo_uso && ` Última consulta: ${new Date(mio.ultimo_uso).toLocaleString('es-ES')}.`}
          </p>
        </div>
      ) : codigo ? (
        <div className="tarjeta">
          <p className="suave" style={{ marginTop: 0 }}>
            Mándale este código por mensaje directo a la cuenta de Instagram de la casa,
            desde tu cuenta personal. Vale {codigo.minutos} minutos.
          </p>
          <div style={{
            fontSize: '2rem', fontFamily: 'var(--mono)', letterSpacing: '.3em',
            textAlign: 'center', padding: '.8rem 0', fontWeight: 700,
          }}>{codigo.codigo}</div>
          <p className="suave" style={{ margin: 0 }}>
            Quien tenga este código queda autorizado como tú, con tu perfil. No lo
            reenvíes: generar otro invalida este.
          </p>
        </div>
      ) : (
        <div className="tarjeta">
          <p className="suave" style={{ marginTop: 0 }}>
            Todavía no puedes preguntar desde Instagram. Genera un código y mándaselo
            por mensaje directo a la cuenta de la casa.
          </p>
          <button disabled={ocupado} onClick={() => void pedirCodigo()}>
            Generar código de alta
          </button>
        </div>
      )}

      {esAdmin && (
        <>
          <h2>Quién puede preguntar</h2>
          <p className="suave">
            A una cuenta de Instagram le escribe cualquiera: solo responde a quien esté
            en esta lista, y con el perfil de esa persona.
          </p>
          {autorizados.length === 0 && (
            <div className="aviso info">Todavía no hay nadie dado de alta.</div>
          )}
          {autorizados.map((a) => (
            <div key={`${a.canal}-${a.id_externo}`} className="tarjeta">
              <div className="fila">
                <strong>{a.nombre ?? a.alias ?? 'Sin nombre'}</strong>
                <span className="suave">{a.canal}</span>
              </div>
              <div className="fila">
                <span className="mono suave" style={{ fontSize: '.75rem' }}>{a.id_externo}</span>
                <span className="suave">
                  {a.ultimo_uso
                    ? `usó el ${new Date(a.ultimo_uso).toLocaleDateString('es-ES')}`
                    : 'sin usar'}
                </span>
              </div>
              <button className="peligro" style={{ marginTop: '.6rem', padding: '.4rem .8rem', minHeight: 38 }}
                      onClick={() => void revocar(a)}>
                Quitar acceso
              </button>
            </div>
          ))}
        </>
      )}

      <p className="suave" style={{ marginTop: '1.5rem' }}>
        <Link href="/ajustes">← Ajustes</Link>
      </p>
    </main>
  );
}
