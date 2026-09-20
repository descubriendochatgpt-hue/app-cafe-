import { NextResponse } from 'next/server';
import { comoAnonimo } from '@/lib/supabase';

/** Lista para el desplegable de acceso. Nombre y perfil, nada más. */
export async function GET() {
  const { data, error } = await comoAnonimo().rpc('usuarios_para_acceso');
  if (error) {
    return NextResponse.json({ error: 'No se pudo cargar la lista de usuarios.' }, { status: 500 });
  }
  return NextResponse.json({ usuarios: data });
}
