import type { Metadata, Viewport } from 'next';
import './globals.css';
import { RegistrarSW } from '@/componentes/RegistrarSW';

export const metadata: Metadata = {
  title: 'Gestión de tueste y stock',
  description: 'Maestro único de inventario y pedidos multicanal',
  manifest: '/manifest.webmanifest',
  appleWebApp: { capable: true, statusBarStyle: 'default', title: 'Tueste' },
  icons: { icon: '/icono-192.png', apple: '/icono-192.png' },
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  // Que no se pueda ampliar evita el zoom accidental al escanear con prisa.
  maximumScale: 1,
  themeColor: '#35543D',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="es">
      <body>
        {children}
        <RegistrarSW />
      </body>
    </html>
  );
}
