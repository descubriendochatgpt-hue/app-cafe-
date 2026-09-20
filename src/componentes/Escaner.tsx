'use client';

/**
 * Lector de códigos con la cámara.
 *
 * Se usa jsQR sobre los fotogramas del vídeo en lugar de la API nativa
 * BarcodeDetector porque Safari en iPhone no la soporta, y media clientela
 * de mercado trabaja con iPhone. Funciona igual en los dos sitios.
 *
 * Cada lectura suena y vibra: en un puesto de feria se escanea sin mirar la
 * pantalla, y el sonido es la confirmación de que ha entrado.
 */
import { useEffect, useRef, useState, useCallback } from 'react';
import jsQR from 'jsqr';

interface Props {
  onLeer: (texto: string) => void;
  /** Milisegundos antes de admitir otra lectura del mismo código. */
  reposo?: number;
  activo?: boolean;
}

export function Escaner({ onLeer, reposo = 1500, activo = true }: Props) {
  const video = useRef<HTMLVideoElement>(null);
  const lienzo = useRef<HTMLCanvasElement>(null);
  const ultima = useRef<{ texto: string; cuando: number }>({ texto: '', cuando: 0 });
  const bucle = useRef<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [destello, setDestello] = useState<'' | 'leido'>('');

  const avisar = useCallback(() => {
    if ('vibrate' in navigator) navigator.vibrate(60);
    try {
      const ctx = new AudioContext();
      const osc = ctx.createOscillator();
      const vol = ctx.createGain();
      osc.frequency.value = 880;
      vol.gain.setValueAtTime(0.08, ctx.currentTime);
      vol.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + 0.12);
      osc.connect(vol).connect(ctx.destination);
      osc.start();
      osc.stop(ctx.currentTime + 0.12);
      setTimeout(() => void ctx.close(), 200);
    } catch {
      // El navegador puede bloquear el audio hasta la primera interacción.
      // La vibración y el destello ya confirman la lectura.
    }
  }, []);

  useEffect(() => {
    if (!activo) return;
    let flujo: MediaStream | null = null;
    let vivo = true;

    void (async () => {
      try {
        flujo = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: 'environment', width: { ideal: 1280 } },
          audio: false,
        });
        if (!vivo || !video.current) { flujo.getTracks().forEach((t) => t.stop()); return; }
        video.current.srcObject = flujo;
        await video.current.play();
        mirar();
      } catch {
        setError(
          'No se pudo abrir la cámara. Revisa el permiso en el navegador; '
          + 'en iPhone, la página tiene que servirse por https.',
        );
      }
    })();

    function mirar() {
      const v = video.current, c = lienzo.current;
      if (!vivo || !v || !c || v.readyState !== v.HAVE_ENOUGH_DATA) {
        bucle.current = requestAnimationFrame(mirar);
        return;
      }

      // Se analiza a resolución reducida: basta para leer un QR y deja el
      // móvil fresco durante una feria entera.
      const ancho = 480;
      const alto = Math.round((v.videoHeight / v.videoWidth) * ancho);
      c.width = ancho; c.height = alto;

      const ctx = c.getContext('2d', { willReadFrequently: true });
      if (!ctx) { bucle.current = requestAnimationFrame(mirar); return; }
      ctx.drawImage(v, 0, 0, ancho, alto);

      const codigo = jsQR(ctx.getImageData(0, 0, ancho, alto).data, ancho, alto, {
        inversionAttempts: 'dontInvert',
      });

      if (codigo?.data) {
        const ahora = Date.now();
        const repetido = codigo.data === ultima.current.texto
          && ahora - ultima.current.cuando < reposo;
        if (!repetido) {
          ultima.current = { texto: codigo.data, cuando: ahora };
          avisar();
          setDestello('leido');
          setTimeout(() => setDestello(''), 320);
          onLeer(codigo.data.trim());
        }
      }

      bucle.current = requestAnimationFrame(mirar);
    }

    return () => {
      vivo = false;
      if (bucle.current !== null) cancelAnimationFrame(bucle.current);
      flujo?.getTracks().forEach((t) => t.stop());
    };
  }, [activo, onLeer, reposo, avisar]);

  if (error) {
    return (
      <div className="aviso error">
        {error}
        <p className="suave" style={{ margin: '.5rem 0 0' }}>
          Puedes seguir trabajando escribiendo el código del lote a mano.
        </p>
      </div>
    );
  }

  return (
    <div className={`visor ${destello}`}>
      <video ref={video} playsInline muted />
      <div className="mira" />
      <canvas ref={lienzo} style={{ display: 'none' }} />
    </div>
  );
}
