import type { Metadata, Viewport } from 'next';

export const metadata: Metadata = {
  title: 'Gestión de tueste y stock',
  description: 'Maestro único de inventario y pedidos multicanal',
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  themeColor: '#35543D',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="es">
      <body>{children}</body>
    </html>
  );
}
