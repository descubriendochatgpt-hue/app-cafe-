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
