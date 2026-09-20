/**
 * Clientes de Supabase.
 *
 *   comoUsuario(jwt) — lleva el JWT de la sesión, así que las políticas RLS
 *     se aplican con el rol de esa persona. Es el camino de todo lo que nace
 *     de alguien pulsando un botón, y también el de los conectores, que usan
 *     un JWT de perfil SISTEMA (ver `sistema.ts`).
 *
 *   comoAnonimo() — sin identificar. Solo llega a lo que está concedido a
 *     `anon`: la lista de acceso y la comprobación del PIN.
 *
 *   comoServicio() — se salta las políticas RLS ENTERAS. No se usa en ningún
 *     camino normal de la aplicación, y está aquí solo para tareas de
 *     mantenimiento que lo necesiten de verdad.
 *
 * El navegador no habla con Supabase: habla con las rutas de este servidor.
 * Así ninguna clave circula, y el control de acceso está en un único sitio.
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

let anonimo: SupabaseClient | null = null;

export function comoAnonimo(): SupabaseClient {
  if (anonimo) return anonimo;
  const env = entorno();
  anonimo = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return anonimo;
}

let servicio: SupabaseClient | null = null;

export function comoServicio(): SupabaseClient {
  if (servicio) return servicio;
  const env = entorno();
  servicio = createClient(env.NEXT_PUBLIC_SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return servicio;
}
