/**
 * El correo diario. Una vez al día, con lo de ayer y lo que hay que mirar.
 *
 * El día se reserva en la base ANTES de mandar nada. Si se apuntara después,
 * dos crones solapados pasarían los dos por la comprobación y saldrían dos
 * correos iguales; con la fecha como clave primaria, el segundo no manda. Y
 * si el proveedor falla, se suelta la reserva para que el siguiente intento
 * pueda hacerlo — mejor un correo tarde que ninguno.
 */
import { NextResponse } from 'next/server';
import { comoSistema } from '@/lib/sistema';
import { autorizada } from '@/lib/cron';
import { baseUrl } from '@/lib/integraciones';
import { avisos, enviar as enviarCorreo, redactar, resumenSchema } from '@/lib/correo';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;

export async function GET(peticion: Request) {
  if (!autorizada(peticion)) {
    return NextResponse.json({ error: 'No autorizada.' }, { status: 401 });
  }

  if (!avisos.activo) {
    return NextResponse.json({
      ok: true, enviado: false,
      motivo: 'Sin configurar: rellena RESEND_API_KEY y AVISOS_PARA en .env.local.',
    });
  }

  const db = await comoSistema();
  const url = new URL(peticion.url);

  // Ayer por defecto. El parámetro existe para poder reenviar un día suelto
  // a mano si el cron no llegó a correr.
  const pedida = url.searchParams.get('fecha');
  const ayer = new Date();
  ayer.setDate(ayer.getDate() - 1);
  const fecha = /^\d{4}-\d{2}-\d{2}$/.test(pedida ?? '')
    ? (pedida as string)
    : (ayer.toISOString().slice(0, 10));

  const { data, error } = await db.rpc('resumen_diario', { p_fecha: fecha });
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  const resumen = resumenSchema.parse(data);

  // Con «avisos_solo_si_hay» puesto, un día tranquilo no genera correo. Es
  // preferible para quien recibiría treinta correos iguales al mes y dejaría
  // de abrirlos; por eso es un parámetro y no una decisión nuestra.
  if (resumen.solo_si_hay && !resumen.hay_avisos) {
    return NextResponse.json({ ok: true, enviado: false, motivo: 'Día tranquilo.', fecha });
  }

  const { data: reservado, error: falloReserva } = await db.rpc('reservar_aviso_diario', {
    p_fecha: fecha, p_destinatarios: avisos.para, p_resumen: resumen,
  });
  if (falloReserva) {
    return NextResponse.json({ error: falloReserva.message }, { status: 500 });
  }
  if (reservado !== true) {
    return NextResponse.json({ ok: true, enviado: false, motivo: 'Ya se mandó hoy.', fecha });
  }

  try {
    await enviarConReintento(redactar(resumen, baseUrl()), avisos.para);
  } catch (e) {
    await db.rpc('soltar_aviso_diario', { p_fecha: fecha });
    return NextResponse.json(
      { error: e instanceof Error ? e.message : 'No se pudo enviar.' }, { status: 502 });
  }

  return NextResponse.json({
    ok: true, enviado: true, fecha, para: avisos.para.length,
    avisos: resumen.hay_avisos,
  });
}

/** Dos intentos con una espera corta: casi todos los fallos son pasajeros. */
async function enviarConReintento(correo: Parameters<typeof enviarCorreo>[0], para: string[]) {
  try {
    await enviarCorreo(correo, para);
  } catch (primero) {
    await new Promise((r) => setTimeout(r, 2000));
    try {
      await enviarCorreo(correo, para);
    } catch {
      throw primero;
    }
  }
}
