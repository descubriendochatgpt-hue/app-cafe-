'use client';

/**
 * Bot de consulta por Telegram.
 *
 * Tres cosas en una pantalla: probar las respuestas (funciona desde el primer
 * día), darse de alta para preguntar desde el móvil, y —para un
 * administrador— poner el bot en marcha y ver quién tiene acceso.
 */
import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';
import { Copiable } from '@/componentes/Copiable';

interface Autorizado {
  canal: string; id_externo: string; usuario_id: string;
  nombre?: string; alias: string | null; creado_en: string; ultimo_uso: string | null;
}

interface EstadoTelegram {
  configurado: boolean; bot?: string | null;
  urlEsperada?: string; urlRegistrada?: string | null; alDia?: boolean;
  pendientes?: number; ultimoError?: string | null; secretoPuesto?: boolean;
  error?: string;
}

const EJEMPLOS = ['ayuda', 'stock', 'mínimos', 'pedidos', 'depósito', 'frescura', 'verde'];

export default function Bot() {
  const [autorizados, setAutorizados] = useState<Autorizado[]>([]);
  const [esAdmin, setEsAdmin] = useState(false);
  const [yo, setYo] = useState('');
  const [tg, setTg] = useState<EstadoTelegram | null>(null);
  const [codigo, setCodigo] = useState<{ codigo: string; minutos: number } | null>(null);
  const [pregunta, setPregunta] = useState('');
  const [respuesta, setRespuesta] = useState<string | null>(null);
  const [ocupado, setOcupado] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const cargar = useCallback(async () => {
    const [rb, rt] = await Promise.all([
      fetch('/api/admin/bot'),
      fetch('/api/admin/telegram'),
    ]);
    if (rb.ok) {
      const d = await rb.json() as { autorizados: Autorizado[]; esAdmin: boolean; yo: string };
      setAutorizados(d.autorizados);
      setEsAdmin(d.esAdmin);
      setYo(d.yo);
    }
    if (rt.ok) setTg(await rt.json() as EstadoTelegram);
  }, []);

  useEffect(() => { void cargar(); }, [cargar]);

  async function pedirCodigo() {
    setOcupado(true); setError(null);
    try {
      const r = await fetch('/api/admin/bot', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ accion: 'codigo' }),
      });
      const d = await r.json() as { error?: string; codigo?: string; minutos?: number };
      if (!r.ok || !d.codigo) { setError(d.error ?? 'No se pudo generar.'); return; }
      setCodigo({ codigo: d.codigo, minutos: d.minutos ?? 15 });
    } finally { setOcupado(false); }
  }

  async function preguntar(texto: string) {
    setOcupado(true); setRespuesta(null); setError(null);
    try {
      const r = await fetch('/api/consulta', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ pregunta: texto }),
      });
      const d = await r.json() as { error?: string; respuesta?: string };
      if (!r.ok) { setError(d.error ?? 'No se pudo responder.'); return; }
      setRespuesta(d.respuesta ?? '');
    } finally { setOcupado(false); }
  }

  async function registrarWebhook() {
    setOcupado(true); setError(null);
    try {
      const r = await fetch('/api/admin/telegram', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ accion: 'registrar' }),
      });
      const d = await r.json() as { error?: string };
      if (!r.ok) { setError(d.error ?? 'No se pudo registrar.'); return; }
      await cargar();
    } finally { setOcupado(false); }
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
  const enlaceAlta = codigo && tg?.bot ? `https://t.me/${tg.bot}?start=${codigo.codigo}` : null;

  return (
    <main>
      <h1>Bot de consulta</h1>
      <p className="sub">Preguntar por el negocio desde el móvil sin abrir la app.</p>

      {error && <div className="aviso error">{error}</div>}

      <h2>Probar aquí</h2>
      <p className="suave">
        Las mismas respuestas que da por Telegram, con tu perfil. Funciona aunque el
        bot no esté configurado todavía.
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

      <h2>Tu acceso desde Telegram</h2>
      {!tg?.configurado ? (
        <div className="aviso info">
          El bot de Telegram no está configurado todavía. Hace falta el token que da
          @BotFather, en el fichero de integraciones.
        </div>
      ) : mio ? (
        <div className="tarjeta">
          <div className="fila">
            <strong>Dado de alta</strong>
            <span className="etiqueta FRESCO">activo</span>
          </div>
          <p className="suave" style={{ margin: '.4rem 0 0' }}>
            Escríbele a {tg.bot ? `@${tg.bot}` : 'el bot'} por Telegram y te responde.
            {mio.ultimo_uso && ` Última consulta: ${new Date(mio.ultimo_uso).toLocaleString('es-ES')}.`}
          </p>
        </div>
      ) : codigo ? (
        <div className="tarjeta">
          {enlaceAlta ? (
            <>
              <p className="suave" style={{ marginTop: 0 }}>
                Abre este enlace en el móvil donde tengas Telegram. Te da de alta sin
                escribir nada. Vale {codigo.minutos} minutos.
              </p>
              <a href={enlaceAlta} target="_blank" rel="noreferrer">
                <button className="ancho" type="button">Abrir en Telegram</button>
              </a>
              <div style={{ marginTop: '.6rem' }}><Copiable texto={enlaceAlta} /></div>
            </>
          ) : (
            <>
              <p className="suave" style={{ marginTop: 0 }}>
                Manda este código al bot por Telegram. Vale {codigo.minutos} minutos.
              </p>
              <div style={{
                fontSize: '2rem', fontFamily: 'var(--mono)', letterSpacing: '.3em',
                textAlign: 'center', padding: '.8rem 0', fontWeight: 700,
              }}>{codigo.codigo}</div>
            </>
          )}
          <p className="suave" style={{ margin: '.6rem 0 0' }}>
            Quien use este enlace queda autorizado <strong>como tú, con tu perfil</strong>.
            No lo reenvíes: generar otro invalida este.
          </p>
        </div>
      ) : (
        <div className="tarjeta">
          <p className="suave" style={{ marginTop: 0 }}>
            Todavía no puedes preguntar desde Telegram.
          </p>
          <button disabled={ocupado} onClick={() => void pedirCodigo()}>
            Generar enlace de alta
          </button>
        </div>
      )}

      {esAdmin && (
        <>
          <h2>Puesta en marcha</h2>
          {tg?.error && <div className="aviso error">{tg.error}</div>}

          {!tg?.configurado ? (
            <div className="tarjeta">
              <p className="suave" style={{ marginTop: 0 }}>
                Habla con <strong>@BotFather</strong> en Telegram, crea un bot con
                <code className="mono"> /newbot</code> y pega su token en el fichero de
                integraciones. No hace falta aprobación de nadie ni cuenta de empresa.
              </p>
              <div className="suave" style={{ marginBottom: '.35rem' }}>
                Esta será la URL del webhook:
              </div>
              <Copiable texto={tg?.urlEsperada ?? ''} />
            </div>
          ) : (
            <div className="tarjeta">
              <div className="fila">
                <strong>{tg.bot ? `@${tg.bot}` : 'Bot conectado'}</strong>
                <span className={`etiqueta ${tg.alDia ? 'FRESCO' : 'AVISO'}`}>
                  {tg.alDia ? 'webhook al día' : 'webhook sin registrar'}
                </span>
              </div>

              {!tg.secretoPuesto && (
                <div className="aviso info" style={{ margin: '.6rem 0 0' }}>
                  Sin <code className="mono">TELEGRAM_WEBHOOK_SECRET</code>, cualquiera que
                  adivine la URL podría mandarle mensajes falsos al bot. Conviene ponerlo.
                </div>
              )}

              {tg.ultimoError && (
                <div className="aviso error" style={{ margin: '.6rem 0 0' }}>
                  Último error que reporta Telegram: {tg.ultimoError}
                </div>
              )}

              {(tg.pendientes ?? 0) > 0 && (
                <p className="suave" style={{ margin: '.5rem 0 0' }}>
                  {tg.pendientes} mensaje(s) sin entregar esperando.
                </p>
              )}

              {!tg.alDia && (
                <button style={{ marginTop: '.7rem' }} disabled={ocupado}
                        onClick={() => void registrarWebhook()}>
                  Registrar el webhook ahora
                </button>
              )}
            </div>
          )}

          <h2>Quién puede preguntar</h2>
          <p className="suave">
            Solo responde a quien esté en esta lista, y con el perfil de esa persona.
          </p>
          {autorizados.length === 0 && (
            <div className="aviso info">Todavía no hay nadie dado de alta.</div>
          )}
          {autorizados.map((a) => (
            <div key={`${a.canal}-${a.id_externo}`} className="tarjeta">
              <div className="fila">
                <strong>{a.nombre ?? a.alias ?? 'Sin nombre'}</strong>
                <span className="suave">{a.alias ?? a.canal}</span>
              </div>
              <div className="fila">
                <span className="mono suave" style={{ fontSize: '.75rem' }}>{a.id_externo}</span>
                <span className="suave">
                  {a.ultimo_uso
                    ? `usó el ${new Date(a.ultimo_uso).toLocaleDateString('es-ES')}`
                    : 'sin usar'}
                </span>
              </div>
              <button className="peligro"
                      style={{ marginTop: '.6rem', padding: '.4rem .8rem', minHeight: 38 }}
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
