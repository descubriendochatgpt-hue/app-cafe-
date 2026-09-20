'use client';

/**
 * Usuarios.
 *
 * Cada persona con su cuenta, no una compartida: cada movimiento del libro
 * queda firmado con quien lo hizo, y eso solo sirve de algo si las cuentas no
 * se comparten.
 */
import { useCallback, useEffect, useState } from 'react';
import Link from 'next/link';

interface Usuario {
  usuario_id: string; nombre: string; rol: string; activo: boolean;
  creado_en: string; fallos: number; bloqueado_hasta: string | null;
}

const ROLES = [
  { valor: 'OPERARIO', texto: 'Operario · escanea y produce, no ve importes' },
  { valor: 'GESTOR', texto: 'Gestor · además precios, pedidos e informes' },
  { valor: 'ADMIN', texto: 'Administrador · además usuarios y parámetros' },
];

export default function Usuarios() {
  const [usuarios, setUsuarios] = useState<Usuario[]>([]);
  const [yo, setYo] = useState('');
  const [cargando, setCargando] = useState(true);
  const [ocupado, setOcupado] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [alta, setAlta] = useState<{ nombre: string; pin: string; rol: string } | null>(null);
  const [pinDe, setPinDe] = useState<string | null>(null);
  const [pinNuevo, setPinNuevo] = useState('');

  const cargar = useCallback(async () => {
    const r = await fetch('/api/admin/usuarios');
    if (!r.ok) {
      const d = await r.json() as { error?: string };
      setError(d.error ?? 'No se pudo cargar.');
      setCargando(false);
      return;
    }
    const d = await r.json() as { usuarios: Usuario[]; yo: string };
    setUsuarios(d.usuarios);
    setYo(d.yo);
    setCargando(false);
  }, []);

  useEffect(() => { void cargar(); }, [cargar]);

  async function actuar(cuerpo: unknown, id: string) {
    setOcupado(id);
    setError(null);
    try {
      const r = await fetch('/api/admin/usuarios', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(cuerpo),
      });
      if (!r.ok) {
        const d = await r.json() as { error?: string };
        setError(d.error ?? 'No se pudo completar.');
        return false;
      }
      await cargar();
      return true;
    } finally {
      setOcupado(null);
    }
  }

  if (cargando) return <main><p className="suave">Cargando…</p></main>;

  return (
    <main>
      <h1>Usuarios</h1>
      <p className="sub">
        Cada persona con su cuenta: los movimientos quedan firmados con quien los hizo.
      </p>

      {error && <div className="aviso error">{error}</div>}

      {alta ? (
        <form
          className="tarjeta"
          onSubmit={async (e) => {
            e.preventDefault();
            if (await actuar({ accion: 'crear', ...alta }, 'nuevo')) setAlta(null);
          }}
        >
          <h2 style={{ marginTop: 0 }}>Nuevo usuario</h2>
          <label>
            Nombre
            <input value={alta.nombre} required minLength={2}
                   onChange={(e) => setAlta({ ...alta, nombre: e.target.value })} />
          </label>
          <label>
            PIN <span className="suave">· de 4 a 8 cifras</span>
            <input
              inputMode="numeric" value={alta.pin} required pattern="[0-9]{4,8}"
              onChange={(e) => setAlta({ ...alta, pin: e.target.value.replace(/\D/g, '') })}
            />
          </label>
          <label>
            Perfil
            <select value={alta.rol} onChange={(e) => setAlta({ ...alta, rol: e.target.value })}>
              {ROLES.map((r) => <option key={r.valor} value={r.valor}>{r.texto}</option>)}
            </select>
          </label>
          <div style={{ display: 'flex', gap: '.5rem' }}>
            <button style={{ flex: 1 }} disabled={ocupado === 'nuevo'}>Crear</button>
            <button type="button" className="secundario" onClick={() => setAlta(null)}>Cancelar</button>
          </div>
        </form>
      ) : (
        <button style={{ marginBottom: '1rem' }}
                onClick={() => setAlta({ nombre: '', pin: '', rol: 'OPERARIO' })}>
          Nuevo usuario
        </button>
      )}

      {usuarios.map((u) => {
        const bloqueado = u.bloqueado_hasta && new Date(u.bloqueado_hasta) > new Date();
        return (
          <div key={u.usuario_id} className="tarjeta" style={{ opacity: u.activo ? 1 : 0.6 }}>
            <div className="fila">
              <strong>{u.nombre}{u.usuario_id === yo && <span className="suave"> · tú</span>}</strong>
              {!u.activo && <span className="etiqueta SIN_FECHA">de baja</span>}
              {bloqueado && <span className="etiqueta CRITICO">bloqueado</span>}
            </div>

            <label style={{ marginTop: '.6rem' }}>
              Perfil
              <select
                value={u.rol} disabled={ocupado === u.usuario_id}
                onChange={(e) => void actuar(
                  { accion: 'rol', usuarioId: u.usuario_id, rol: e.target.value }, u.usuario_id)}
              >
                {ROLES.map((r) => <option key={r.valor} value={r.valor}>{r.texto}</option>)}
              </select>
            </label>

            {pinDe === u.usuario_id ? (
              <div style={{ display: 'flex', gap: '.4rem' }}>
                <input
                  inputMode="numeric" value={pinNuevo} placeholder="PIN nuevo" style={{ marginTop: 0 }}
                  onChange={(e) => setPinNuevo(e.target.value.replace(/\D/g, ''))}
                />
                <button
                  style={{ flex: 'none' }}
                  disabled={pinNuevo.length < 4 || ocupado === u.usuario_id}
                  onClick={async () => {
                    if (await actuar({ accion: 'pin', usuarioId: u.usuario_id, pin: pinNuevo }, u.usuario_id)) {
                      setPinDe(null); setPinNuevo('');
                    }
                  }}
                >
                  Cambiar
                </button>
                <button className="secundario" style={{ flex: 'none' }}
                        onClick={() => { setPinDe(null); setPinNuevo(''); }}>
                  Cancelar
                </button>
              </div>
            ) : (
              <div style={{ display: 'flex', gap: '.5rem', flexWrap: 'wrap' }}>
                <button className="secundario" style={{ padding: '.4rem .8rem', minHeight: 38 }}
                        onClick={() => { setPinDe(u.usuario_id); setPinNuevo(''); }}>
                  Cambiar PIN
                </button>
                {bloqueado && (
                  <button className="secundario" style={{ padding: '.4rem .8rem', minHeight: 38 }}
                          disabled={ocupado === u.usuario_id}
                          onClick={() => void actuar(
                            { accion: 'desbloquear', usuarioId: u.usuario_id }, u.usuario_id)}>
                    Desbloquear
                  </button>
                )}
                {u.usuario_id !== yo && (
                  <button
                    className={u.activo ? 'peligro' : 'secundario'}
                    style={{ padding: '.4rem .8rem', minHeight: 38 }}
                    disabled={ocupado === u.usuario_id}
                    onClick={() => void actuar(
                      { accion: 'activar', usuarioId: u.usuario_id, activo: !u.activo }, u.usuario_id)}
                  >
                    {u.activo ? 'Dar de baja' : 'Reactivar'}
                  </button>
                )}
              </div>
            )}

            {u.fallos > 0 && (
              <p className="suave" style={{ margin: '.5rem 0 0', fontSize: '.78rem' }}>
                {u.fallos} intento(s) fallido(s)
                {bloqueado && `, bloqueado hasta las ${new Date(u.bloqueado_hasta!).toLocaleTimeString('es-ES')}`}
              </p>
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
