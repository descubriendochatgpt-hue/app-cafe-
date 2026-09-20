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

  useEffect(() => {
    void (async () => {
      try {
        const r = await fetch('/api/auth/usuarios');
        const d = (await r.json()) as { usuarios?: Usuario[] };
        setUsuarios(d.usuarios ?? []);
        if (d.usuarios?.length === 1) setUsuarioId(d.usuarios[0]!.usuario_id);
      } catch {
        setError('No se pudo conectar. Comprueba la configuración de Supabase.');
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

      <form onSubmit={entrar}>
        <label>
          Quién eres
          <select value={usuarioId} onChange={(e) => setUsuarioId(e.target.value)} required>
            <option value="">Elige…</option>
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
