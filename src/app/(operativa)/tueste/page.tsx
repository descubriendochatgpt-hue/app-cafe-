'use client';

/**
 * Registrar un tueste.
 *
 * Es una transformación, no dos apuntes sueltos: consume kilos de verde y
 * produce paquetes en la misma operación. La merma se calcula con los pesos
 * reales y se avisa si se sale de lo razonable, porque una merma del 40 %
 * casi siempre significa que alguien se ha equivocado tecleando.
 */
import { useMemo, useState } from 'react';
import { useApp } from '@/componentes/Estado';
import { RecepcionVerde } from '@/componentes/RecepcionVerde';
import { registrar } from '@/lib/sincronizacion';
import { nuevaOperacionId, ahora } from '@/lib/uuid';

export default function Tueste() {
  const { catalogo, subir } = useApp();
  const [pestana, setPestana] = useState<'tostar' | 'verde'>('tostar');
  const [loteVerde, setLoteVerde] = useState('');
  const [kg, setKg] = useState('');
  const [sku, setSku] = useState('');
  const [uds, setUds] = useState('');
  const [nota, setNota] = useState('');
  const [ocupado, setOcupado] = useState(false);
  const [mensaje, setMensaje] = useState<{ tipo: 'ok' | 'error' | 'info'; texto: string } | null>(null);

  const verdes = useMemo(
    () => (catalogo?.saldos ?? [])
      .filter((s) => s.ubicacion_id === 'ALMACEN' && s.cantidad > 0)
      .map((s) => ({ saldo: s, lote: catalogo?.lotes.find((l) => l.lote_id === s.lote_id) }))
      .filter((x) => x.lote?.clase === 'VERDE'),
    [catalogo],
  );

  const paquetes = useMemo(
    () => (catalogo?.articulos ?? []).filter((a) => a.clase === 'PAQUETE'),
    [catalogo],
  );

  // Los gramos salen del formato del artículo. Buscarlos en un lote ya
  // existente fallaría justo la primera vez que se tuesta una referencia.
  const gramos = useMemo(() => {
    const articulo = catalogo?.articulos.find((a) => a.sku === sku);
    if (!articulo?.formato_id) return null;
    return catalogo?.formatos.find((f) => f.formato_id === articulo.formato_id)?.gramos ?? null;
  }, [catalogo, sku]);

  const merma = useMemo(() => {
    const entra = Number(kg), n = Number(uds);
    if (!entra || !n || !gramos) return null;
    const sale = (n * gramos) / 1000;
    return { sale, pct: ((entra - sale) / entra) * 100 };
  }, [kg, uds, gramos]);

  const disponibleVerde = verdes.find((v) => v.saldo.lote_id === loteVerde)?.saldo.disponible ?? 0;
  const pasaDeLoQueHay = Number(kg) > disponibleVerde;

  async function guardar(e: React.FormEvent) {
    e.preventDefault();
    setOcupado(true);
    setMensaje(null);
    try {
      const r = await registrar('TUESTE', {
        operacionId: nuevaOperacionId(),
        consumos: [{ lote_id: loteVerde, cantidad: Number(kg) }],
        producciones: [{ sku, cantidad: Number(uds) }],
        ubicacionId: 'ALMACEN',
        ocurridoEn: ahora(),
        nota: nota || null,
      });
      setMensaje(
        r.bloqueadas > 0
          ? { tipo: 'error', texto: 'El servidor lo ha rechazado. Míralo en Ajustes → Pendientes.' }
          : r.sinRed
            ? { tipo: 'info', texto: 'Guardado en el móvil. Se subirá al recuperar cobertura.' }
            : { tipo: 'ok', texto: 'Tueste registrado y stock actualizado.' },
      );
      setKg(''); setUds(''); setNota('');
      await subir();
    } finally {
      setOcupado(false);
    }
  }

  return (
    <main>
      <h1>{pestana === 'tostar' ? 'Nuevo tueste' : 'Recibir café verde'}</h1>
      <p className="sub">
        {pestana === 'tostar'
          ? 'Consume café verde y produce paquetes, en una sola operación.'
          : 'Da de alta un saco. Es el principio de la cadena de trazabilidad.'}
      </p>

      <div className="chips">
        <button className={pestana === 'tostar' ? 'on' : ''} onClick={() => setPestana('tostar')}>
          Tostar
        </button>
        <button className={pestana === 'verde' ? 'on' : ''} onClick={() => setPestana('verde')}>
          Recibir verde
        </button>
      </div>

      {pestana === 'verde' && <RecepcionVerde />}

      {pestana === 'tostar' && <>
      {mensaje && <div className={`aviso ${mensaje.tipo}`}>{mensaje.texto}</div>}

      <form onSubmit={(e) => void guardar(e)}>
        <label>
          Saco de café verde
          <select value={loteVerde} onChange={(e) => setLoteVerde(e.target.value)} required>
            <option value="">Elige…</option>
            {verdes.map((v) => (
              <option key={v.saldo.lote_id} value={v.saldo.lote_id}>
                {v.lote?.cafe} · quedan {v.saldo.disponible} kg
              </option>
            ))}
          </select>
        </label>

        <label>
          Kilos de verde usados
          <input
            type="number" step="0.1" min="0.1" inputMode="decimal"
            value={kg} onChange={(e) => setKg(e.target.value)} required
          />
        </label>
        {loteVerde && pasaDeLoQueHay && (
          <div className="aviso error">
            Solo quedan {disponibleVerde} kg de ese saco.
          </div>
        )}

        <label>
          Qué se ha producido
          <select value={sku} onChange={(e) => setSku(e.target.value)} required>
            <option value="">Elige…</option>
            {paquetes.map((a) => {
              const formato = catalogo?.formatos.find((f) => f.formato_id === a.formato_id);
              return (
                <option key={a.sku} value={a.sku}>
                  {a.cafe_id} · {formato?.nombre ?? a.sku}
                </option>
              );
            })}
          </select>
        </label>

        <label>
          Paquetes producidos
          <input
            type="number" step="1" min="1" inputMode="numeric"
            value={uds} onChange={(e) => setUds(e.target.value)} required
          />
        </label>

        <label>
          Notas <span className="suave">(opcional)</span>
          <input value={nota} onChange={(e) => setNota(e.target.value)} />
        </label>

        {merma && (
          <div className={`aviso ${merma.pct < 10 || merma.pct > 22 ? 'error' : 'info'}`}>
            Merma <strong>{merma.pct.toFixed(1)} %</strong> · entran {Number(kg)} kg,
            salen {merma.sale.toFixed(2)} kg.
            {(merma.pct < 10 || merma.pct > 22) && (
              <> Lo normal está entre el 10 % y el 22 %: revisa las cifras antes de guardar.</>
            )}
          </div>
        )}

        <button className="ancho" disabled={ocupado || pasaDeLoQueHay}>
          {ocupado ? 'Guardando…' : 'Registrar tueste'}
        </button>
      </form>
      </>}
    </main>
  );
}
