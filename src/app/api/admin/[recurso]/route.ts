import { NextResponse } from 'next/server';
import { sesionActual, tokenActual, alcanza } from '@/lib/sesion';
import { comoUsuario } from '@/lib/supabase';
import { RECURSOS, esRecurso, explicar } from '@/lib/admin';

export const dynamic = 'force-dynamic';

async function contexto(nombre: string) {
  const sesion = await sesionActual();
  const token = await tokenActual();
  if (!sesion || !token) {
    return { error: NextResponse.json({ error: 'Hay que identificarse.' }, { status: 401 }) };
  }
  if (!esRecurso(nombre)) {
    return { error: NextResponse.json({ error: 'Recurso desconocido.' }, { status: 404 }) };
  }
  const recurso = RECURSOS[nombre]!;
  if (!alcanza(sesion.rol, recurso.minimo)) {
    return {
      error: NextResponse.json(
        { error: `Se necesita perfil de ${recurso.minimo.toLowerCase()}.` }, { status: 403 }),
    };
  }
  return { recurso, db: comoUsuario(token) };
}

export async function GET(
  _p: Request, { params }: { params: Promise<{ recurso: string }> },
) {
  const { recurso: nombre } = await params;
  const ctx = await contexto(nombre);
  if (ctx.error) return ctx.error;

  const { data, error } = await ctx.db!
    .from(ctx.recurso!.tabla).select('*').order(ctx.recurso!.orden);

  if (error) return NextResponse.json({ error: explicar(error) }, { status: 500 });
  return NextResponse.json({ filas: data ?? [] });
}

export async function POST(
  peticion: Request, { params }: { params: Promise<{ recurso: string }> },
) {
  const { recurso: nombre } = await params;
  const ctx = await contexto(nombre);
  if (ctx.error) return ctx.error;

  const leido = ctx.recurso!.esquema.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) {
    return NextResponse.json(
      {
        error: 'Hay campos mal rellenos.',
        campos: leido.error.issues.map((i) => ({
          campo: i.path.join('.'), mensaje: i.message,
        })),
      },
      { status: 400 },
    );
  }

  // Alta y modificación son la misma operación: la clave decide cuál.
  const { data, error } = await ctx.db!
    .from(ctx.recurso!.tabla)
    .upsert(leido.data as Record<string, unknown>, { onConflict: ctx.recurso!.clave })
    .select()
    .maybeSingle();

  if (error) return NextResponse.json({ error: explicar(error) }, { status: 400 });
  return NextResponse.json({ ok: true, fila: data });
}
