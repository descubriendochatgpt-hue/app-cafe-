/**
 * Lectura y validación de la configuración. Se comprueba al arrancar y no
 * en mitad de una venta: una variable mal puesta tiene que dar la cara en el
 * despliegue, no a las ocho de la tarde en un mercado.
 */
import { z } from 'zod';

const esquema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.string().url(),
  SUPABASE_ANON_KEY: z.string().min(20),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(20),
  SUPABASE_JWT_SECRET: z.string().min(32, 'El secreto del JWT necesita al menos 32 caracteres'),
  NEXT_PUBLIC_APP_URL: z.string().url().optional(),
  SESION_HORAS: z.coerce.number().int().positive().max(24 * 7).default(12),
  CRON_SECRET: z.string().min(16).optional(),
});

export type Entorno = z.infer<typeof esquema>;

let memoria: Entorno | null = null;

/**
 * Lo mismo que `entorno()`, pero contando qué falla en vez de reventar.
 *
 * Lo usa el diagnóstico de `/api/salud`. Tiene que salir de ESTE esquema y no
 * de una lista paralela: una comprobación que mire cosas distintas de las que
 * mira la aplicación acaba diciendo que todo está bien mientras la aplicación
 * se cae, que es peor que no tener comprobación.
 */
export function revisarEntorno():
  | { ok: true }
  | { ok: false; problemas: { campo: string; mensaje: string }[] } {
  const leido = esquema.safeParse(process.env);
  if (leido.success) return { ok: true };

  // El camino y el mensaje, nunca el valor: esto se lee sin identificarse.
  return {
    ok: false,
    problemas: leido.error.issues.map((i) => ({
      campo: i.path.join('.') || '(desconocido)',
      mensaje: i.message,
    })),
  };
}

export function entorno(): Entorno {
  if (memoria) return memoria;

  const leido = esquema.safeParse(process.env);
  if (!leido.success) {
    const detalle = leido.error.issues
      .map((i) => `  · ${i.path.join('.')}: ${i.message}`)
      .join('\n');
    throw new Error(`Configuración incompleta:\n${detalle}\n\nMira integraciones.ejemplo.env.`);
  }

  memoria = leido.data;
  return memoria;
}
