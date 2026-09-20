'use client';

import { useState } from 'react';

/** Un texto con botón de copiar: estas URL se pegan en otro sitio, no se leen. */
export function Copiable({ texto }: { texto: string }) {
  const [copiado, setCopiado] = useState(false);

  return (
    <div style={{ display: 'flex', gap: '.4rem', alignItems: 'stretch' }}>
      <code
        className="mono"
        style={{
          flex: 1, padding: '.5rem .6rem', background: 'var(--fondo)',
          border: '1px solid var(--borde)', borderRadius: 8,
          overflowX: 'auto', whiteSpace: 'nowrap',
        }}
      >
        {texto}
      </code>
      <button
        className="secundario"
        style={{ padding: '.4rem .7rem', minHeight: 0, flex: 'none' }}
        onClick={async () => {
          try {
            await navigator.clipboard.writeText(texto);
            setCopiado(true);
            setTimeout(() => setCopiado(false), 1600);
          } catch {
            // Sin permiso de portapapeles: el texto está a la vista para copiarlo a mano.
          }
        }}
      >
        {copiado ? '✓' : 'Copiar'}
      </button>
    </div>
  );
}
