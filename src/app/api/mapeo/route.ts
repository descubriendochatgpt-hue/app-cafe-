import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';

const cuerpo = z.object({
  canal: z.enum(['loyverse', 'woocommerce', 'eci']),
  codigoExterno: z.string().min(1).max(200),
  sku: z.string().regex(/^[A-Z0-9][A-Z0-9-]{1,39}$/).nullable(),
  descripcion: z.string().max(200).nullish(),
  // Datos propios del canal. En WooCommerce hace falta saber si el código es
  // una variación y de qué producto cuelga: la API para actualizar su stock
  // es distinta según el caso.
  datos: z.object({
    tipo: z.enum(['simple', 'variacion']).optional(),
    padre: z.number().int().positive().nullable().optional(),
  }).optional(),
});

/** Crea o quita un mapeo. `sku: null` lo borra. */
export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'GESTOR')) {
    return NextResponse.json({ error: 'Se necesita perfil de gestor.' }, { status: 403 });
  }

  const leido = cuerpo.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) {
    return NextResponse.json({ error: 'Datos de mapeo incorrectos.' }, { status: 400 });
  }

  const db = comoUsuario(token);
  const { canal, codigoExterno, sku, descripcion, datos } = leido.data;

  if (sku === null) {
    const { error } = await db.from('mapeo_articulos').delete()
      .eq('canal', canal).eq('codigo_externo', codigoExterno);
    if (error) return NextResponse.json({ error: error.message }, { status: 500 });
    return NextResponse.json({ ok: true, borrado: true });
  }

  const { error } = await db.from('mapeo_articulos').upsert({
    canal, codigo_externo: codigoExterno, sku,
    descripcion_externa: descripcion ?? null,
    datos: datos ?? {},
  }, { onConflict: 'canal,codigo_externo' });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json({ ok: true });
}
