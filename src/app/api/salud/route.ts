/**
 * Diagnóstico de la instalación. Lo que se mira después de desplegar.
 *
 * Existe porque la primera puesta en marcha es donde más se pierde el tiempo:
 * la pantalla de acceso solo puede decir «no se pudo cargar la lista», y a
 * partir de ahí toca adivinar entre una clave mal pegada, una base que no
 * responde y un esquema a medio aplicar. Esto lo dice en una línea.
 *
 * QUÉ CUENTA Y QUÉ NO
 *
 * Se puede abrir sin identificarse —si hiciera falta entrar para usarlo, no
 * serviría justo cuando hace falta, que es cuando no se puede entrar—. Así
 * que aquí NO sale ningún valor: ni claves, ni fragmentos, ni longitudes
 * exactas, ni el mensaje crudo de la base, que puede describir el esquema.
 *
 * Solo sale qué variable falta —y sus nombres ya están publicados en el
 * fichero de ejemplo del repositorio— y en cuál de cuatro sitios está el
 * problema. Saber que un servidor está mal configurado no le sirve de nada a
 * quien quiera atacarlo: en ese estado la aplicación no deja entrar a nadie.
 */
import { NextResponse } from 'next/server';
import { revisarEntorno } from '@/lib/entorno';

export const dynamic = 'force-dynamic';

/** Traduce el fallo a uno de los cuatro sitios donde puede estar. */
function donde(codigo: string | undefined, mensaje: string): {
  estado: string; significa: string; arreglo: string;
} {
  if (codigo === 'PGRST202' || /could not find the function|schema cache/i.test(mensaje)) {
    return {
      estado: 'funcion_desconocida',
      significa: 'La base responde, pero no encuentra usuarios_para_acceso().',
      arreglo: 'O el esquema no se aplicó, o PostgREST tiene la lista vieja en '
             + 'memoria. En el editor SQL: notify pgrst, \'reload schema\';',
    };
  }
  if (codigo === '42501' || /permission denied|insufficient/i.test(mensaje)) {
    return {
      estado: 'permiso_denegado',
      significa: 'La función existe, pero anon no tiene permiso para ejecutarla.',
      arreglo: 'El esquema se aplicó a medias: vuelve a pegarlo entero.',
    };
  }
  if (/fetch failed|ENOTFOUND|ECONNREFUSED|getaddrinfo|network/i.test(mensaje)) {
    return {
      estado: 'no_alcanzable',
      significa: 'No se llega al servidor de Supabase.',
      arreglo: 'Revisa NEXT_PUBLIC_SUPABASE_URL: sin barra final, sin espacios, '
             + 'y que el proyecto no esté pausado.',
    };
  }
  if (codigo === '401' || /invalid.*(api|key|jwt)|unauthorized/i.test(mensaje)) {
    return {
      estado: 'clave_rechazada',
      significa: 'Supabase responde, pero rechaza la clave.',
      arreglo: 'SUPABASE_ANON_KEY no es la de este proyecto, o se coló un '
             + 'espacio o un salto de línea al pegarla.',
    };
  }
  return {
    estado: 'otro',
    significa: 'La base contestó con un error que no sé clasificar.',
    arreglo: 'Mira el registro del servidor: ahí va el motivo entero.',
  };
}

export async function GET() {
  // La misma validación que usa la aplicación, no una parecida. Una variable
  // puede estar puesta y no valer: una clave que se copió a medias o un
  // secreto de JWT demasiado corto hacen fallar TODAS las rutas, no solo el
  // acceso, y mirando solo si está definida eso no se ve.
  const config = revisarEntorno();

  if (!config.ok) {
    return NextResponse.json({
      ok: false,
      estado: 'configuracion_incompleta',
      problemas: config.problemas,
      arreglo: 'Vercel → Settings → Environment Variables. Márcalas en '
             + 'Production y vuelve a desplegar: las variables nuevas no se '
             + 'aplican a un despliegue ya hecho.',
    });
  }

  // La configuración está completa. Ahora, ¿contesta la base?
  try {
    const { comoAnonimo } = await import('@/lib/supabase');
    const { data, error } = await comoAnonimo().rpc('usuarios_para_acceso');

    if (error) {
      console.error('[salud] usuarios_para_acceso falló:', error.code, error.message);
      return NextResponse.json({ ok: false, ...donde(error.code, error.message ?? '') });
    }

    const cuantos = Array.isArray(data) ? data.length : 0;
    return NextResponse.json({
      ok: cuantos > 0,
      estado: cuantos > 0 ? 'todo_correcto' : 'sin_usuarios',
      usuarios: cuantos,
      ...(cuantos === 0 && {
        significa: 'La base responde pero no hay ningún usuario activo.',
        arreglo: 'La semilla crea un «Administrador». Si no está, el esquema se '
               + 'aplicó a medias: vuelve a pegarlo entero.',
      }),
    });
  } catch (e) {
    const mensaje = e instanceof Error ? e.message : String(e);
    console.error('[salud] excepción:', mensaje);
    return NextResponse.json({ ok: false, ...donde(undefined, mensaje) });
  }
}
