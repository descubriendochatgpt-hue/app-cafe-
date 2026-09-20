/**
 * El bot, independiente del canal por el que llegue la pregunta.
 *
 * Telegram es un transporte; la lógica vive aquí. Así se puede probar sin
 * pasar por Telegram —la pantalla de Ajustes hace las mismas preguntas— y
 * añadir mañana otro canal se queda en escribir su fichero de transporte.
 */
import { comoSistema } from './sistema';
import { comoUsuario } from './supabase';
import { firmarToken } from './jwt';
import { entorno } from './entorno';
import { responder } from './consultas';
import { esCodigo, limpiarComando } from './telegram';
import type { Rol } from './tipos';

export interface Respuesta {
  texto: string | null;
  /** Para el registro: qué ha pasado con este mensaje. */
  resultado: 'respondido' | 'alta' | 'no-autorizado' | 'limitado' | 'codigo-invalido';
  usuario?: string;
}

interface Identidad {
  usuario_id: string; nombre: string; rol: Rol; limitado: boolean;
}

export async function atender(
  canal: 'telegram' | 'prueba',
  idExterno: string,
  texto: string,
  alias?: string,
): Promise<Respuesta> {
  const sistema = await comoSistema();

  const { data, error } = await sistema.rpc('quien_es_bot', {
    p_canal: canal, p_id_externo: idExterno,
  });
  if (error) throw new Error(`No se pudo resolver quién pregunta: ${error.message}`);

  const identidad = data as Identidad | null;

  if (identidad?.limitado) {
    return {
      texto: 'Has hecho muchas consultas seguidas. Prueba dentro de un rato.',
      resultado: 'limitado',
    };
  }

  /* ── Todavía no es nadie: ¿está dándose de alta? ── */
  if (!identidad) {
    const codigo = esCodigo(texto);
    if (codigo) {
      const alta = await sistema.rpc('canjear_codigo_bot', {
        p_canal: canal, p_id_externo: idExterno, p_codigo: codigo, p_alias: alias ?? null,
      });
      const r = alta.data as { ok: boolean; nombre?: string } | null;

      if (r?.ok) {
        return {
          texto: `Listo, ${r.nombre}. Ya puedes preguntarme.\n\n`
               + 'Escribe "ayuda" para ver qué sé contestar.',
          resultado: 'alta',
          usuario: r.nombre,
        };
      }
      return {
        texto: 'Ese código no vale o ha caducado. Genera otro desde Ajustes → Bot.',
        resultado: 'codigo-invalido',
      };
    }

    // Al bot le puede escribir cualquiera que dé con él. A quien no conocemos
    // no se le cuenta nada del negocio, ni siquiera que existe un bot.
    const { data: parametro } = await sistema
      .from('parametros').select('valor').eq('clave', 'bot_respuesta_desconocido').maybeSingle();

    const respuesta = (parametro?.valor ?? '').trim();
    return { texto: respuesta || null, resultado: 'no-autorizado' };
  }

  /* ── Autorizado: se consulta CON SU PERFIL ── */
  // No es el bot quien decide qué enseñar: se firma un token con su usuario y
  // son las políticas RLS de siempre las que deciden. Un operario que pregunte
  // por márgenes no obtiene nada porque la consulta no se los devuelve.
  const token = await firmarToken(
    { usuarioId: identidad.usuario_id, nombre: identidad.nombre, rol: identidad.rol },
    entorno().SUPABASE_JWT_SECRET,
    1,
  );

  // `/stock etiopía` y `stock etiopía` son la misma pregunta: Telegram manda
  // la barra cuando se usa el menú de comandos.
  const texto_respuesta = await responder(
    comoUsuario(token), limpiarComando(texto), identidad.rol);
  return { texto: texto_respuesta, resultado: 'respondido', usuario: identidad.nombre };
}
