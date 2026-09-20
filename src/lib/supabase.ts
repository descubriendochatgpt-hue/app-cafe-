/**
 * Clientes de Supabase.
 *
 * Hay dos, y la diferencia importa:
 *
 *   comoUsuario(jwt) — lleva el JWT de la sesión, así que las políticas RLS
 *     se aplican con el rol de esa persona. Es el que se usa para todo lo
 *     que nace de alguien pulsando un botón.
 *
 *   comoSistema() — usa la clave de servicio y se salta RLS entera. Solo
 *     para conectores y tareas programadas, donde no hay persona detrás.
 *     Nunca se expone al navegador.
 *
 * El navegador no habla con Supabase: habla con las rutas de este servidor.
 * Así la clave pública tampoco circula, y el control de acceso está en un
 * único sitio en vez de repartido entre cliente y servidor.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { entorno } from './entorno';

export function comoUsuario(jwt: string): SupabaseClient {
  const env = entorno();
  return createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

let sistema: SupabaseClient | null = null;

export function comoSistema(): SupabaseClient {
  if (sistema) return sistema;
  const env = entorno();
  sistema = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return sistema;
}
