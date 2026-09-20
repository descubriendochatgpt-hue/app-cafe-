import { NextResponse } from 'next/server';
import { z } from 'zod';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { explicar } from '@/lib/admin';

export const dynamic = 'force-dynamic';

/**
 * Asignación de códigos EAN-13.
 *
 * «Generar» toma el siguiente número libre del prefijo de GS1 de la empresa.
 * «Escribir» acepta uno que ya os hayan dado, comprobando el dígito de
 * control: así no se cuela un código mal copiado que luego falle en la caja
 * de una tienda ajena.
 */
const cuerpo = z.discriminatedUnion('accion', [
  z.object({ accion: z.literal('generar'), sku: z.string().regex(/^[A-Z0-9][A-Z0-9-]{1,39}$/) }),
  z.object({
    accion: z.literal('escribir'),
    sku: z.string().regex(/^[A-Z0-9][A-Z0-9-]{1,39}$/),
    ean: z.string().trim().regex(/^[0-9]{13}$/, 'Un EAN-13 son exactamente 13 cifras').or(z.literal('')),
  }),
]);

export async function POST(peticion: Request) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) return NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 });
  if (!alcanza(sesion.rol, 'GESTOR')) {
    return NextResponse.json({ error: 'Se necesita perfil de gestor.' }, { status: 403 });
  }

  const leido = cuerpo.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) {
    return NextResponse.json(
      { error: leido.error.issues[0]?.message ?? 'Datos no válidos.' }, { status: 400 });
  }

  const db = comoUsuario(token);
  const { data, error } = leido.data.accion === 'generar'
    ? await db.rpc('generar_ean', { p_sku: leido.data.sku })
    : await db.rpc('asignar_ean', { p_sku: leido.data.sku, p_ean: leido.data.ean || null });

  if (error) return NextResponse.json({ error: explicar(error) }, { status: 400 });
  return NextResponse.json({ ok: true, ean: data });
}
