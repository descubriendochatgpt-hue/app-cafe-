import { NextResponse } from 'next/server';
import { comoAnonimo } from '@/lib/supabase';

/** Lista para el desplegable de acceso. Solo el nombre: el perfil no. */
export async function GET() {
  const { data, error } = await comoAnonimo().rpc('usuarios_para_acceso');

  if (error) {
    // Al navegador, un mensaje sin detalles: esta ruta la ve cualquiera sin
    // identificarse, y el motivo exacto de un fallo de base de datos le dice
    // demasiado a quien está probando por dónde entrar.
    //
    // Al registro del servidor, el motivo entero. Sin esto, montar el sistema
    // por primera vez es adivinar: la pantalla solo enseñaba un desplegable
    // vacío y no había dónde mirar.
    console.error('[acceso] usuarios_para_acceso falló:', error.message, error.details ?? '');
    return NextResponse.json({ error: 'No se pudo cargar la lista de usuarios.' }, { status: 500 });
  }

  return NextResponse.json({ usuarios: data ?? [] });
}
