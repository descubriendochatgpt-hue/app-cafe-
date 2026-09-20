'use client';

import { useEffect } from 'react';

/** Instala el service worker. Sin él, la app no abre sin cobertura. */
export function RegistrarSW() {
  useEffect(() => {
    if (!('serviceWorker' in navigator)) return;
    const alCargar = () => {
      navigator.serviceWorker.register('/sw.js').catch(() => {
        // En desarrollo por http sin localhost el navegador lo bloquea.
        // No es motivo para romper nada: la app funciona igual con red.
      });
    };
    if (document.readyState === 'complete') alCargar();
    else window.addEventListener('load', alCargar);
    return () => window.removeEventListener('load', alCargar);
  }, []);
  return null;
}
