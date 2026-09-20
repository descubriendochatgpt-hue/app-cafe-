'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { useApp } from './Estado';
import { alcanza, type Rol } from '@/lib/tipos';

/**
 * Cabecera con el indicador de conexión. En un mercado es la información más
 * importante de la pantalla: dice si lo que acabas de cobrar ya está a salvo
 * en el servidor o sigue esperando en el móvil.
 */
export function Cabecera({ nombre, rol }: { nombre: string; rol: Rol }) {
  const { conectado, enCola, atascadas, subir } = useApp();

  const [clase, texto] = atascadas.length > 0
    ? ['cola', `${atascadas.length} sin resolver`]
    : enCola > 0
      ? ['cola', `${enCola} sin subir`]
      : conectado
        ? ['on', 'Al día']
        : ['off', 'Sin conexión'];

  return (
    <header className="barra">
      <span className="titulo">{nombre}</span>
      <button
        className="estado secundario"
        style={{ border: 0, background: 'none', padding: '.25rem', minHeight: 0 }}
        onClick={() => void subir()}
        title="Subir ahora lo que quede pendiente"
      >
        <span className={`punto ${clase}`} />
        {texto}
      </button>
      <span className="suave" style={{ fontSize: '.72rem' }}>{rol.toLowerCase()}</span>
    </header>
  );
}

const SECCIONES = [
  { href: '/panel', icono: '📊', texto: 'Panel', minimo: 'GESTOR' },
  { href: '/escanear', icono: '📷', texto: 'Escanear', minimo: 'OPERARIO' },
  { href: '/pedidos', icono: '📋', texto: 'Pedidos', minimo: 'OPERARIO' },
  { href: '/stock', icono: '📦', texto: 'Stock', minimo: 'OPERARIO' },
  { href: '/tueste', icono: '🔥', texto: 'Tueste', minimo: 'OPERARIO' },
  { href: '/etiquetas', icono: '🏷️', texto: 'Etiquetas', minimo: 'OPERARIO' },
  { href: '/informes', icono: '📈', texto: 'Informes', minimo: 'OPERARIO' },
  { href: '/ajustes', icono: '⚙️', texto: 'Ajustes', minimo: 'OPERARIO' },
] as const;

export function Navegacion({ rol }: { rol: Rol }) {
  const ruta = usePathname();
  // La barra de un móvil solo da de sí hasta cierto punto. El panel es la
  // pantalla de quien mira el negocio, así que a un operario no le ocupa
  // sitio: la ruta le sigue funcionando si llega a ella, con las cifras de
  // dinero fuera, pero no le estorba en el camino de cobrar.
  const visibles = SECCIONES.filter((s) => alcanza(rol, s.minimo));
  return (
    <nav className="inferior">
      {visibles.map((s) => (
        <Link key={s.href} href={s.href} className={ruta.startsWith(s.href) ? 'activo' : ''}>
          <span className="icono" aria-hidden>{s.icono}</span>
          {s.texto}
        </Link>
      ))}
    </nav>
  );
}
