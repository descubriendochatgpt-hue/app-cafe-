'use client';

/**
 * Entrada de un saco de café verde.
 *
 * Es el principio de la cadena: sin esto no hay nada que tostar, y la
 * trazabilidad de una bolsa vendida acaba aquí cuando se recorre hacia atrás.
 */
import { useState } from 'react';
import { useApp } from '@/componentes/Estado';
import { registrar } from '@/lib/sincronizacion';
import { nuevaOperacionId, ahora } from '@/lib/uuid';

export function RecepcionVerde() {
  const { catalogo, subir } = useApp();
  const [sku, setSku] = useState('');
  const [kg, setKg] = useState('');
  const [proveedor, setProveedor] = useState('');
  const [fecha, setFecha] = useState(new Date().toISOString().slice(0, 10));
  const [precio, setPrecio] = useState('');
  const [nota, setNota] = useState('');
  const [ocupado, setOcupado] = useState(false);
  const [mensaje, setMensaje] = useState<{ tipo: 'ok' | 'error' | 'info'; texto: string } | null>(null);

  const verdes = (catalogo?.articulos ?? []).filter((a) => a.clase === 'VERDE');
  const hayPrecios = (catalogo?.precios.length ?? 0) > 0;

  async function guardar(e: React.FormEvent) {
    e.preventDefault();
    setOcupado(true);
    setMensaje(null);
    try {
      const r = await registrar('RECEPCION_VERDE', {
        operacionId: nuevaOperacionId(),
        sku,
        cantidadKg: Number(kg),
        ubicacionId: 'ALMACEN',
        proveedor: proveedor || null,
        fechaRecepcion: fecha,
        precioKg: precio ? Number(precio) : null,
        ocurridoEn: ahora(),
        nota: nota || null,
      });
      setMensaje(
        r.bloqueadas > 0
          ? { tipo: 'error', texto: 'El servidor lo ha rechazado. Míralo en Ajustes → Pendientes.' }
          : r.sinRed
            ? { tipo: 'info', texto: 'Guardado en el móvil. Se subirá al recuperar cobertura.' }
            : { tipo: 'ok', texto: `Saco registrado: ${kg} kg en el almacén.` },
      );
      setKg(''); setPrecio(''); setNota('');
      await subir();
    } finally {
      setOcupado(false);
    }
  }

  if (verdes.length === 0) {
    return (
      <div className="aviso info">
        No hay ninguna referencia de café verde dada de alta. Créala primero en
        Ajustes → Catálogo → Referencias, con el tipo «Café verde».
      </div>
    );
  }

  return (
    <form onSubmit={(e) => void guardar(e)}>
      {mensaje && <div className={`aviso ${mensaje.tipo}`}>{mensaje.texto}</div>}

      <label>
        Qué café
        <select value={sku} onChange={(e) => setSku(e.target.value)} required>
          <option value="">Elige…</option>
          {verdes.map((a) => (
            <option key={a.sku} value={a.sku}>{a.sku}</option>
          ))}
        </select>
      </label>

      <label>
        Kilos recibidos
        <input type="number" step="0.1" min="0.1" inputMode="decimal"
               value={kg} onChange={(e) => setKg(e.target.value)} required />
      </label>

      <label>
        Proveedor <span className="suave">(opcional)</span>
        <input value={proveedor} onChange={(e) => setProveedor(e.target.value)} />
      </label>

      <label>
        Fecha de recepción
        <input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} required />
      </label>

      {hayPrecios && (
        <label>
          Precio por kilo <span className="suave">(opcional, para el coste real)</span>
          <input type="number" step="0.01" min="0" inputMode="decimal"
                 value={precio} onChange={(e) => setPrecio(e.target.value)} />
        </label>
      )}

      <label>
        Notas <span className="suave">(opcional)</span>
        <input value={nota} onChange={(e) => setNota(e.target.value)}
               placeholder="Huila 2026 · saco 3, por ejemplo" />
      </label>

      <button className="ancho" disabled={ocupado || !sku || !kg}>
        {ocupado ? 'Guardando…' : 'Registrar entrada'}
      </button>
    </form>
  );
}
