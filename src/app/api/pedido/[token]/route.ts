/**
 * Formulario de pedido de hostelería. Es el único camino PÚBLICO de la
 * aplicación: no hay sesión, el enlace es la credencial.
 *
 * Por eso aquí no se confía en nada de lo que llega:
 *   · el token se comprueba en la base, no aquí;
 *   · el precio lo pone el servidor, nunca el formulario;
 *   · un enlace revocado y uno inventado dan la misma respuesta, para no
 *     decirle a nadie cuál de las dos cosas es.
 */
import { NextResponse } from 'next/server';
import { z } from 'zod';
import { comoSistema } from '@/lib/sistema';
import { nuevaOperacionId } from '@/lib/uuid';

export const dynamic = 'force-dynamic';

const TOKEN = /^[0-9a-f]{32}$/;

export async function GET(
  _peticion: Request,
  { params }: { params: Promise<{ token: string }> },
) {
  const { token } = await params;
  if (!TOKEN.test(token)) {
    return NextResponse.json({ error: 'Enlace no válido.' }, { status: 404 });
  }

  const db = await comoSistema();
  const { data, error } = await db.rpc('catalogo_pedido', { p_token: token });

  if (error) {
    return NextResponse.json({ error: 'No se pudo cargar el catálogo.' }, { status: 500 });
  }
  if (!data) {
    return NextResponse.json(
      { error: 'Este enlace ya no está activo. Pide uno nuevo a tu proveedor.' },
      { status: 404 },
    );
  }

  return NextResponse.json(data);
}

const cuerpo = z.object({
  // Lo genera el navegador del cliente antes de enviar: si el botón se pulsa
  // dos veces o la conexión se corta a mitad, el reenvío trae el mismo
  // identificador y la base reconoce el pedido como ya registrado.
  operacionId: z.string().uuid().optional(),
  lineas: z.array(z.object({
    sku: z.string().regex(/^[A-Z0-9][A-Z0-9-]{1,39}$/),
    cantidad: z.number().int().positive().max(999),
  })).min(1).max(60),
  nota: z.string().max(300).nullish(),
});

export async function POST(
  peticion: Request,
  { params }: { params: Promise<{ token: string }> },
) {
  const { token } = await params;
  if (!TOKEN.test(token)) {
    return NextResponse.json({ error: 'Enlace no válido.' }, { status: 404 });
  }

  const leido = cuerpo.safeParse(await peticion.json().catch(() => null));
  if (!leido.success) {
    return NextResponse.json({ error: 'El pedido no tiene un formato válido.' }, { status: 400 });
  }

  const db = await comoSistema();
  const { data, error } = await db.rpc('crear_pedido_hosteleria', {
    p_operacion_id: leido.data.operacionId ?? nuevaOperacionId(),
    p_token: token,
    p_lineas: leido.data.lineas,
    p_nota: leido.data.nota ?? null,
    p_ocurrido_en: new Date().toISOString(),
  });

  if (error) {
    // Los mensajes de estas funciones están escritos para que los lea un
    // cliente («el enlace ya no está activo», «demasiados pedidos seguidos»),
    // así que se devuelven tal cual en vez de esconderlos tras un genérico.
    const esDeEnlace = /enlace|pedidos de este enlace/i.test(error.message);
    return NextResponse.json({ error: error.message }, { status: esDeEnlace ? 403 : 400 });
  }

  return NextResponse.json(data);
}
