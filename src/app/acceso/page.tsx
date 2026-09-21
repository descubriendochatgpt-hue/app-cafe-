'use client';

/**
 * Acceso por PIN. Un desplegable y cuatro cifras: con guantes o con las manos
 * mojadas, escribir un correo y una contraseña no es una opción.
 */
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';

// La lista pública ya no dice quién es administrador: saber a quién
// atacar le ahorraba la mitad del trabajo a quien prueba PIN.
interface Usuario { usuario_id: string; nombre: string }

export default function Acceso() {
  const router = useRouter();
  const [usuarios, setUsuarios] = useState<Usuario[]>([]);
  const [usuarioId, setUsuarioId] = useState('');
  const [pin, setPin] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [entrando, setEntrando] = useState(false);
  const [cargandoLista, setCargandoLista] = useState(true);

  useEffect(() => {
    void (async () => {
      try {
        const r = await fetch('/api/auth/usuarios');
        // Distinguir «no pude cargar la lista» de «no hay nadie dado de alta»
        // importa más de lo que parece: las dos se veían como un desplegable
        // vacío, y quien acaba de montar el sistema se queda mirando una
        // pantalla que no le dice qué ha hecho mal.
        if (!r.ok) {
          setError('No se pudo cargar la lista de usuarios. Revisa las claves de '
                 + 'Supabase en el servidor; el detalle está en el registro.');
          return;
        }
        const d = (await r.json()) as { usuarios?: Usuario[] };
        setUsuarios(d.usuarios ?? []);
        if (d.usuarios?.length === 1) setUsuarioId(d.usuarios[0]!.usuario_id);
      } catch {
        setError('No se pudo conectar con el servidor.');
      } finally {
        setCargandoLista(false);
      }
    })();
  }, []);

  async function entrar(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setEntrando(true);
    try {
      const r = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ usuarioId, pin }),
      });
      if (!r.ok) {
        const d = (await r.json()) as { error?: string };
        setError(d.error ?? 'No se pudo entrar.');
        setPin('');
        return;
      }
      router.push('/escanear');
      router.refresh();
    } catch {
      setError('Sin conexión con el servidor.');
    } finally {
      setEntrando(false);
    }
  }

  return (
    <main style={{ maxWidth: '22rem', paddingTop: '3rem' }}>
      <h1>Gestión de tueste y stock</h1>
      <p className="sub">Identifícate para empezar.</p>

      {error && <div className="aviso error">{error}</div>}

      {!cargandoLista && !error && usuarios.length === 0 && (
        <div className="aviso info">
          La base responde, pero no hay ningún usuario activo. La semilla crea un
          «Administrador»: si no aparece, es que el esquema se aplicó a medias.
        </div>
      )}

      <form onSubmit={entrar}>
        <label>
          Quién eres
          <select value={usuarioId} onChange={(e) => setUsuarioId(e.target.value)} required>
            <option value="">
              {cargandoLista ? 'Cargando…'
                : error ? '—'
                : usuarios.length === 0 ? 'No hay nadie dado de alta'
                : 'Elige…'}
            </option>
            {usuarios.map((u) => (
              <option key={u.usuario_id} value={u.usuario_id}>{u.nombre}</option>
            ))}
          </select>
        </label>

        <label>
          PIN
          <input
            type="password" inputMode="numeric" autoComplete="off"
            pattern="[0-9]{4,8}" value={pin} required
            onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))}
            style={{ fontSize: '1.4rem', letterSpacing: '.4em', textAlign: 'center' }}
          />
        </label>

        <button className="ancho" disabled={entrando || !usuarioId || pin.length < 4}>
          {entrando ? 'Comprobando…' : 'Entrar'}
        </button>
      </form>
    </main>
  );
}
