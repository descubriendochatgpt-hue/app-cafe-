import { firmarSistema } from './jwt';
import { comoUsuario } from './supabase';
import { entorno } from './entorno';
import type { SupabaseClient } from '@supabase/supabase-js';

/**
 * Cliente con perfil SISTEMA, para los conectores y las tareas programadas.
 *
 * Se firma un JWT con rol SISTEMA en vez de usar la clave de servicio. La
 * diferencia importa: la clave de servicio se salta las políticas RLS
 * enteras, así que un fallo en un conector podría escribir cualquier cosa en
 * cualquier tabla. Con un JWT, el webhook pasa por las mismas puertas que una
 * persona, solo que con permiso para todas ellas.
 */
export async function comoSistema(): Promise<SupabaseClient> {
  return comoUsuario(await firmarSistema(entorno().SUPABASE_JWT_SECRET));
}
