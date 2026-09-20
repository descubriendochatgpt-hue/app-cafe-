'use client';

import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { useApp } from '@/componentes/Estado';
import { quitarDeCola } from '@/lib/almacenLocal';

export default function Ajustes() {
  const router = useRouter();
  const { enCola, atascadas, conectado, catalogo, subir } = useApp();

  async function salir() {
    await fetch('/api/auth/logout', { method: 'POST' });
    router.push('/acceso');
    router.refresh();
  }

  return (
    <main>
      <h1>Ajustes</h1>

      <h2>Estado</h2>
      <div className="tarjeta">
        <div className="fila">
          <span>Conexión</span>
          <span>{conectado ? 'con red' : 'sin red'}</span>
        </div>
        <div className="fila">
          <span>Operaciones sin subir</span>
          <span>{enCola}</span>
        </div>
        <div className="fila">
          <span>Catálogo descargado</span>
          <span className="suave">
            {catalogo ? new Date(catalogo.descargado).toLocaleString('es-ES') : 'nunca'}
          </span>
        </div>
        <button className="secundario" style={{ marginTop: '.75rem' }} onClick={() => void subir()}>
          Subir y refrescar ahora
        </button>
      </div>

      {atascadas.length > 0 && (
        <>
          <h2>Pendientes de resolver</h2>
          <p className="sub">
            Reintentar no las va a arreglar: hace falta decidir algo. Se guardan aquí en vez de
            perderse o de dar vueltas para siempre.
          </p>
          {atascadas.map((o) => (
            <div key={o.operacionId} className="tarjeta">
              <div className="fila">
                <strong>{o.tipo}</strong>
                <span className="suave">{new Date(o.creadoEn).toLocaleString('es-ES')}</span>
              </div>
              <div className="aviso error" style={{ margin: '.5rem 0 0' }}>{o.ultimoError}</div>
              <div className="mono suave" style={{ marginTop: '.4rem' }}>{o.operacionId}</div>
              <button
                className="peligro" style={{ marginTop: '.6rem', padding: '.4rem .8rem', minHeight: 38 }}
                onClick={async () => { await quitarDeCola(o.operacionId); await subir(); }}
              >
                Descartar
              </button>
            </div>
          ))}
        </>
      )}

      <h2>Configuración</h2>
      <div className="tarjeta">
        <div className="fila"><Link href="/ajustes/conciliacion">Conciliación →</Link></div>
        <div className="fila"><Link href="/ajustes/integraciones">Integraciones y webhooks →</Link></div>
        <div className="fila"><Link href="/ajustes/loyverse">Artículos de Loyverse →</Link></div>
        <div className="fila"><Link href="/ajustes/woocommerce">Productos de WooCommerce →</Link></div>
        <div className="fila"><Link href="/ajustes/hosteleria">Enlaces de hostelería →</Link></div>
      </div>

      <button className="secundario ancho" style={{ marginTop: '1.5rem' }} onClick={() => void salir()}>
        Cerrar sesión
      </button>
    </main>
  );
}
