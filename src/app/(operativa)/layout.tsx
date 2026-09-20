import { redirect } from 'next/navigation';
import { sesionActual } from '@/lib/sesion';
import { ProveedorEstado } from '@/componentes/Estado';
import { Cabecera, Navegacion } from '@/componentes/Armazon';

export default async function LayoutOperativa({ children }: { children: React.ReactNode }) {
  const sesion = await sesionActual();
  if (!sesion) redirect('/acceso');

  return (
    <ProveedorEstado>
      <Cabecera nombre={sesion.nombre} rol={sesion.rol} />
      {children}
      <Navegacion rol={sesion.rol} />
    </ProveedorEstado>
  );
}
