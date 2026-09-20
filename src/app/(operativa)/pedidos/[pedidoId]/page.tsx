'use client';

/**
 * Preparar y empaquetar un pedido.
 *
 * Son dos cosas distintas y se ven separadas a propósito:
 *
 *   PREPARAR   saca el café del estante. Toca el inventario, y se anota del
 *              lote que realmente se ha cogido. Va por la cola, así que
 *              funciona sin cobertura.
 *   EMPAQUETAR lo mete en cajas. No toca el inventario: la mercancía ya
 *              salió. Guarda qué lote fue a qué caja, que es lo que permite
 *              avisar solo a los clientes afectados si un lote sale malo.
 */
import { useCallback, useEffect, useMemo, useState } from 'react';
import { useParams } from 'next/navigation';
import Link from 'next/link';
import { Escaner } from '@/componentes/Escaner';
import { useApp } from '@/componentes/Estado';
import { registrar } from '@/lib/sincronizacion';
import { nuevaOperacionId, ahora } from '@/lib/uuid';

interface Linea { linea_id: string; sku: string; cantidad: number; servidas: number; importe?: number }
interface Contenido { lote_id: string; sku: string; cantidad: number }
interface Bulto {
  bulto_id: string; caja_id: string | null; estado: string;
  unidades: number; peso_g: number | null; seguimiento: string | null;
  contenido: Contenido[];
}
interface Caja { caja_id: string; nombre: string }
interface Pedido {
  pedido_id: string; numero: string; canal: string; estado: string;
  fecha: string; notas: string | null; total?: number;
}

type Fase = 'preparar' | 'empaquetar';

export default function DetallePedido() {
  const { pedidoId } = useParams<{ pedidoId: string }>();
  const { lote: buscarLote, subir, conectado } = useApp();

  const [pedido, setPedido] = useState<Pedido | null>(null);
  const [lineas, setLineas] = useState<Linea[]>([]);
  const [bultos, setBultos] = useState<Bulto[]>([]);
  const [cajas, setCajas] = useState<Caja[]>([]);
  const [sugerencia, setSugerencia] = useState<{ caja_id: string | null; nombre?: string; nota?: string } | null>(null);
  const [fase, setFase] = useState<Fase>('preparar');
  const [bultoAbierto, setBultoAbierto] = useState<string | null>(null);
  const [seguimiento, setSeguimiento] = useState('');
  const [mensaje, setMensaje] = useState<{ tipo: 'ok' | 'error' | 'info'; texto: string } | null>(null);
  const [cargando, setCargando] = useState(true);
  const [ocupado, setOcupado] = useState(false);
  const [manual, setManual] = useState('');

  const cargar = useCallback(async () => {
    const r = await fetch(`/api/pedidos/${pedidoId}`);
    if (!r.ok) {
      const d = await r.json() as { error?: string };
      setMensaje({ tipo: 'error', texto: d.error ?? 'No se pudo cargar el pedido.' });
      setCargando(false);
      return;
    }
    const d = await r.json() as {
      pedido: Pedido; lineas: Linea[]; bultos: Bulto[]; cajas: Caja[];
      sugerencia: { caja_id: string | null; nombre?: string; nota?: string } | null;
    };
    setPedido(d.pedido);
    setLineas(d.lineas);
    setBultos(d.bultos);
    setCajas(d.cajas);
    setSugerencia(d.sugerencia);
    setBultoAbierto(d.bultos.find((b) => b.estado === 'ABIERTO')?.bulto_id ?? null);
    setCargando(false);
  }, [pedidoId]);

  useEffect(() => { void cargar(); }, [cargar]);

  const pendiente = useMemo(
    () => lineas.reduce((s, l) => s + (Number(l.cantidad) - Number(l.servidas)), 0),
    [lineas],
  );
  const empaquetado = useMemo(
    () => bultos.reduce((s, b) => s + Number(b.unidades), 0),
    [bultos],
  );
  const servido = useMemo(
    () => lineas.reduce((s, l) => s + Number(l.servidas), 0),
    [lineas],
  );

  const alLeer = useCallback(async (texto: string) => {
    const lote = buscarLote(texto);
    if (!lote) {
      setMensaje({ tipo: 'error', texto: `No conozco el código «${texto}».` });
      return;
    }

    setOcupado(true);
    try {
      if (fase === 'preparar') {
        const r = await registrar('PREPARACION', {
          operacionId: nuevaOperacionId(),
          pedidoId,
          loteId: lote.lote_id,
          cantidad: 1,
          ocurridoEn: ahora(),
        });
        setMensaje(
          r.bloqueadas > 0
            ? { tipo: 'error', texto: 'Rechazado: puede que ese lote no sea de este pedido.' }
            : r.sinRed
              ? { tipo: 'info', texto: `${lote.cafe} · guardado, se subirá al recuperar cobertura` }
              : { tipo: 'ok', texto: `${lote.cafe} · preparado` },
        );
        await subir();
        await cargar();
        return;
      }

      // Empaquetar necesita conexión: no toca el inventario y un bulto a
      // medio montar sin subir sería más lío que utilidad.
      if (!conectado) {
        setMensaje({ tipo: 'error', texto: 'Empaquetar necesita conexión. Prepara ahora y empaqueta después.' });
        return;
      }
      if (!bultoAbierto) {
        setMensaje({ tipo: 'error', texto: 'Abre un bulto antes de meter nada.' });
        return;
      }

      const r = await fetch(`/api/pedidos/${pedidoId}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ accion: 'anadir', bultoId: bultoAbierto, loteId: lote.lote_id, cantidad: 1 }),
      });
      if (!r.ok) {
        const d = await r.json() as { error?: string };
        setMensaje({ tipo: 'error', texto: d.error ?? 'No se pudo añadir.' });
        return;
      }
      setMensaje({ tipo: 'ok', texto: `${lote.cafe} · a la caja` });
      await cargar();
    } finally {
      setOcupado(false);
    }
  }, [fase, pedidoId, bultoAbierto, buscarLote, subir, cargar, conectado]);

  async function accion(cuerpo: unknown) {
    setOcupado(true);
    try {
      const r = await fetch(`/api/pedidos/${pedidoId}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(cuerpo),
      });
      if (!r.ok) {
        const d = await r.json() as { error?: string };
        setMensaje({ tipo: 'error', texto: d.error ?? 'No se pudo completar.' });
        return;
      }
      setMensaje(null);
      await cargar();
    } finally {
      setOcupado(false);
    }
  }

  if (cargando) return <main><p className="suave">Cargando…</p></main>;
  if (!pedido) return <main><div className="aviso error">{mensaje?.texto}</div></main>;

  return (
    <main>
      <h1>{pedido.numero}</h1>
      <p className="sub">
        {pedido.canal} · {pedido.estado.toLowerCase()}
        {pendiente > 0 ? ` · faltan ${pendiente} por preparar` : ' · todo preparado'}
      </p>

      <div className="chips">
        <button className={fase === 'preparar' ? 'on' : ''} onClick={() => setFase('preparar')}>
          Preparar
        </button>
        <button className={fase === 'empaquetar' ? 'on' : ''} onClick={() => setFase('empaquetar')}>
          Empaquetar
        </button>
      </div>

      {pedido.notas && <div className="aviso info">{pedido.notas}</div>}

      {fase === 'preparar' ? (
        <>
          {pendiente === 0 ? (
            <div className="aviso ok">
              Todo preparado. Pasa a empaquetar.
            </div>
          ) : (
            <Escaner onLeer={(t) => void alLeer(t)} activo={!ocupado} />
          )}

          {mensaje && <div className={`aviso ${mensaje.tipo}`} style={{ marginTop: '.85rem' }}>{mensaje.texto}</div>}

          <form
            style={{ display: 'flex', gap: '.5rem', margin: '.85rem 0' }}
            onSubmit={(e) => { e.preventDefault(); if (manual.trim()) { void alLeer(manual.trim()); setManual(''); } }}
          >
            <input value={manual} onChange={(e) => setManual(e.target.value.toUpperCase())}
                   placeholder="…o escribe el código del lote" className="mono" style={{ marginTop: 0 }} />
            <button className="secundario" type="submit">Añadir</button>
          </form>

          <h2>Qué lleva</h2>
          {lineas.map((l) => {
            const total = Number(l.cantidad);
            const hecho = Number(l.servidas);
            const pct = total > 0 ? Math.round((hecho / total) * 100) : 0;
            return (
              <div key={l.linea_id} className="tarjeta">
                <div className="fila">
                  <strong className="mono">{l.sku}</strong>
                  <span className={hecho >= total ? '' : 'suave'}>
                    {hecho} de {total}
                  </span>
                </div>
                <div style={{
                  height: 8, borderRadius: 4, background: 'var(--fondo)',
                  border: '1px solid var(--borde)', marginTop: '.5rem', overflow: 'hidden',
                }}>
                  <div style={{
                    width: `${pct}%`, height: '100%',
                    background: hecho >= total ? 'var(--fresco)' : 'var(--marca)',
                  }} />
                </div>
              </div>
            );
          })}
        </>
      ) : (
        <>
          {servido === 0 && (
            <div className="aviso info">
              Todavía no has preparado nada. Empaquetar solo anota qué lote va en qué caja.
            </div>
          )}

          {sugerencia && (
            <div className="aviso info">
              {sugerencia.caja_id
                ? <>Cabe todo en la <strong>{sugerencia.nombre}</strong>.</>
                : sugerencia.nota}
            </div>
          )}

          {!bultoAbierto ? (
            <div className="tarjeta">
              <p className="suave" style={{ marginTop: 0 }}>Abre un bulto para empezar.</p>
              <div style={{ display: 'flex', gap: '.5rem', flexWrap: 'wrap' }}>
                {cajas.map((c) => (
                  <button
                    key={c.caja_id}
                    className={sugerencia?.caja_id === c.caja_id ? '' : 'secundario'}
                    style={{ padding: '.5rem .9rem', minHeight: 40 }}
                    disabled={ocupado}
                    onClick={() => void accion({ accion: 'crear-bulto', cajaId: c.caja_id })}
                  >
                    {c.nombre}
                  </button>
                ))}
                <button className="secundario" style={{ padding: '.5rem .9rem', minHeight: 40 }}
                        disabled={ocupado}
                        onClick={() => void accion({ accion: 'crear-bulto', cajaId: null })}>
                  Sin caja
                </button>
              </div>
            </div>
          ) : (
            <>
              <Escaner onLeer={(t) => void alLeer(t)} activo={!ocupado} />
              {mensaje && <div className={`aviso ${mensaje.tipo}`} style={{ marginTop: '.85rem' }}>{mensaje.texto}</div>}
              <div style={{ display: 'flex', gap: '.5rem', margin: '.85rem 0' }}>
                <input value={seguimiento} onChange={(e) => setSeguimiento(e.target.value)}
                       placeholder="Nº de seguimiento (opcional)" style={{ marginTop: 0 }} />
                <button style={{ flex: 'none' }} disabled={ocupado}
                        onClick={() => void accion({
                          accion: 'cerrar-bulto', bultoId: bultoAbierto,
                          seguimiento: seguimiento || null,
                        })}>
                  Cerrar bulto
                </button>
              </div>
            </>
          )}

          <h2>Bultos</h2>
          <p className="suave">
            Empaquetado {empaquetado} de {servido} preparados.
          </p>
          {bultos.length === 0 && <div className="aviso info">Todavía no hay ningún bulto.</div>}
          {bultos.map((b, i) => (
            <div key={b.bulto_id} className="tarjeta">
              <div className="fila">
                <strong>Bulto {i + 1}{b.caja_id ? ` · ${b.caja_id}` : ''}</strong>
                <span className={`etiqueta ${b.estado === 'CERRADO' ? 'FRESCO' : 'AVISO'}`}>
                  {b.estado.toLowerCase()}
                </span>
              </div>
              <div className="fila">
                <span className="suave">{Number(b.unidades)} paquetes</span>
                {b.peso_g && <span className="suave">{(b.peso_g / 1000).toFixed(2)} kg</span>}
              </div>
              {b.seguimiento && (
                <div className="mono suave" style={{ marginTop: '.3rem' }}>{b.seguimiento}</div>
              )}
              <table style={{ marginTop: '.5rem' }}>
                <tbody>
                  {b.contenido.map((c) => (
                    <tr key={c.lote_id}>
                      <td className="mono" style={{ fontSize: '.75rem' }}>{c.lote_id}</td>
                      <td className="num">{Number(c.cantidad)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ))}
        </>
      )}

      <p className="suave" style={{ marginTop: '1.5rem' }}>
        <Link href="/pedidos">← Pedidos</Link>
      </p>
    </main>
  );
}
