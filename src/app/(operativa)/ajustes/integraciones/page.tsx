import Link from 'next/link';
import { inventario, baseUrl } from '@/lib/integraciones';
import { Copiable } from '@/componentes/Copiable';

/**
 * Estado de las integraciones.
 *
 * Es el acompañante del fichero `integraciones.ejemplo.env`: ese dice qué
 * rellenar, y esta pantalla dice si ha surtido efecto y qué URL hay que pegar
 * en el panel de cada proveedor. Entre los dos no debería hacer falta mirar
 * el código para conectar un canal.
 */
export const dynamic = 'force-dynamic';

const ETIQUETA = {
  lista: { texto: 'lista', clase: 'FRESCO' },
  incompleta: { texto: 'a medias', clase: 'AVISO' },
  sin_configurar: { texto: 'sin configurar', clase: 'SIN_FECHA' },
} as const;

export default function Integraciones() {
  const canales = inventario();
  const base = baseUrl();
  const enLocal = base.includes('localhost');

  return (
    <main>
      <h1>Integraciones</h1>
      <p className="sub">
        Todo se rellena en un único sitio: <code className="mono">.env.local</code>, copiado de
        <code className="mono"> integraciones.ejemplo.env</code>. Aquí solo se ve el resultado.
      </p>

      {enLocal && (
        <div className="aviso info">
          <strong>NEXT_PUBLIC_APP_URL</strong> apunta a localhost, así que las URL de abajo solo
          valen para pruebas. Ponla con el dominio real antes de darlas de alta en Loyverse o
          WooCommerce: es la base con la que se construyen.
        </div>
      )}

      {canales.map((c) => (
        <div key={c.id} className="tarjeta">
          <div className="fila">
            <strong>{c.nombre}</strong>
            <span className={`etiqueta ${ETIQUETA[c.estado].clase}`}>
              {ETIQUETA[c.estado].texto}
            </span>
          </div>
          <p className="suave" style={{ margin: '.3rem 0 .7rem' }}>{c.descripcion}</p>

          {c.ranuras.length > 0 && (
            <table>
              <tbody>
                {c.ranuras.map((r) => (
                  <tr key={r.variable}>
                    <td className="mono" style={{ opacity: r.rellena ? 1 : 0.6 }}>
                      {r.variable}
                      {r.obligatoria && !r.rellena && <span style={{ color: 'var(--viejo)' }}> *</span>}
                    </td>
                    <td className="num">{r.rellena ? '✓' : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}

          {c.webhooks.length > 0 && (
            <div style={{ marginTop: '.85rem' }}>
              <div className="suave" style={{ marginBottom: '.35rem' }}>
                Pega esta URL en el panel de {c.nombre}:
              </div>
              {c.webhooks.map((w) => (
                <div key={w.evento} style={{ marginBottom: '.45rem' }}>
                  <Copiable texto={w.url} />
                  <div className="suave mono" style={{ fontSize: '.75rem' }}>
                    evento: {w.evento}{w.nota ? ` · ${w.nota}` : ''}
                  </div>
                </div>
              ))}
            </div>
          )}

          <div className="aviso info" style={{ marginTop: '.75rem', marginBottom: 0 }}>
            {c.siguientePaso}
          </div>
        </div>
      ))}

      <p className="suave" style={{ marginTop: '1.5rem' }}>
        <Link href="/ajustes">← Ajustes</Link>
      </p>
    </main>
  );
}
