'use client';

import { useState } from 'react';

/**
 * Asignación del EAN-13 de una referencia.
 *
 * «Generar» toma el siguiente libre del prefijo de GS1 de la casa. «Escribir»
 * admite uno ya dado, y el servidor comprueba el dígito de control antes de
 * aceptarlo: un código mal copiado falla en la caja de la tienda, donde ya no
 * hay forma de arreglarlo.
 */
export function EanDeArticulo({
  sku, ean, alCambiar,
}: { sku: string; ean: string | null; alCambiar: () => Promise<void> }) {
  const [escribiendo, setEscribiendo] = useState(false);
  const [valor, setValor] = useState(ean ?? '');
  const [ocupado, setOcupado] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function enviar(cuerpo: unknown) {
    setOcupado(true);
    setError(null);
    try {
      const r = await fetch('/api/admin/ean', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(cuerpo),
      });
      if (!r.ok) {
        const d = await r.json() as { error?: string };
        setError(d.error ?? 'No se pudo asignar.');
        return;
      }
      setEscribiendo(false);
      await alCambiar();
    } finally {
      setOcupado(false);
    }
  }

  if (escribiendo) {
    return (
      <div style={{ width: '100%' }}>
        <div style={{ display: 'flex', gap: '.4rem' }}>
          <input
            className="mono" value={valor} inputMode="numeric" maxLength={13}
            placeholder="13 cifras" style={{ marginTop: 0 }}
            onChange={(e) => setValor(e.target.value.replace(/\D/g, ''))}
          />
          <button style={{ flex: 'none' }} disabled={ocupado}
                  onClick={() => void enviar({ accion: 'escribir', sku, ean: valor })}>
            Guardar
          </button>
          <button className="secundario" style={{ flex: 'none' }}
                  onClick={() => { setEscribiendo(false); setError(null); }}>
            Cancelar
          </button>
        </div>
        {error && <div className="aviso error" style={{ marginTop: '.4rem' }}>{error}</div>}
      </div>
    );
  }

  return (
    <>
      <button className="secundario" style={{ padding: '.4rem .8rem', minHeight: 38 }}
              disabled={ocupado} onClick={() => void enviar({ accion: 'generar', sku })}>
        {ean ? 'Regenerar EAN' : 'Generar EAN'}
      </button>
      <button className="secundario" style={{ padding: '.4rem .8rem', minHeight: 38 }}
              onClick={() => setEscribiendo(true)}>
        Escribir EAN
      </button>
      {error && <div className="aviso error" style={{ width: '100%', marginTop: '.4rem' }}>{error}</div>}
    </>
  );
}
