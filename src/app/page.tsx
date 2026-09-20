import { redirect } from 'next/navigation';
import { sesionActual } from '@/lib/sesion';

export default async function Inicio() {
  redirect((await sesionActual()) ? '/escanear' : '/acceso');
}
