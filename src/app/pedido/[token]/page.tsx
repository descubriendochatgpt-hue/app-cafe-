import type { Metadata } from 'next';
import { Formulario } from './Formulario';

export const metadata: Metadata = {
  title: 'Hacer pedido',
  // Un enlace de pedido no tiene por qué acabar en un buscador.
  robots: { index: false, follow: false },
};

export default async function PaginaPedido({
  params,
}: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  return <Formulario token={token} />;
}
