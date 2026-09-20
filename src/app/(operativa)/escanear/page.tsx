'use client';

/**
 * La pantalla que más se usa.
 *
 * Se elige PRIMERO el modo y después se escanea muchas veces seguidas sin
 * volver a tocar nada. Es lo que permite despachar una cola de feria sin
 * mirar el móvil entre cliente y cliente.
 *
 * Todo lo que se registra aquí sale primero al almacén local y después al
 * servidor. Si no hay cobertura, el trabajo sigue: el contador de la cabecera
 * dice cuánto queda por subir.
 */
import { useCallback, useMemo, useState } from 'react';
import { Escaner } from '@/componentes/Escaner';
import { useApp } from '@/componentes/Estado';
import { registrar } from '@/lib/sincronizacion';
import { nuevaOperacionId, ahora } from '@/lib/uuid';
import type { LoteDetalle } from '@/lib/almacenLocal';

type Modo = 'CONSULTAR' | 'VENTA' | 'ENTRADA' | 'SALIDA' | 'TRASLADO' | 'INVENTARIO';

const MODOS: { id: Modo; texto: string; ayuda: string }[] = [
  { id: 'CONSULTAR',  texto: 'Consultar',  ayuda: 'Dice qué es y cuánto queda. No cambia nada.' },
  { id: 'VENTA',      texto: 'Venta',      ayuda: 'Escanea lo que se lleva el cliente y cobra.' },
  { id: 'ENTRADA',    texto: 'Entrada',    ayuda: 'Cada lectura suma. También deja el lote repuesto como activo.' },
  { id: 'SALIDA',     texto: 'Salida',     ayuda: 'Cada lectura resta: muestras, autoconsumo, roturas.' },
  { id: 'TRASLADO',   texto: 'Traslado',   ayuda: 'Mueve entre ubicaciones. Servir a ECI es esto.' },
  { id: 'INVENTARIO', texto: 'Inventario', ayuda: 'Cuenta escaneando y genera los ajustes al cerrar.' },
];

interface Linea { lote: LoteDetalle; uds: number }

export default function Escanear() {
  const { catalogo, lote: buscarLote, saldoDe, subir } = useApp();
  const [modo, setModo] = useState<Modo>('CONSULTAR');
  const [ubicacion, setUbicacion] = useState('TIENDA');
  const [destino, setDestino] = useState('TIENDA');
  const [cesta, setCesta] = useState<Linea[]>([]);
  const [ultimo, setUltimo] = useState<LoteDetalle | null>(null);
  const [mensaje, setMensaje] = useState<{ tipo: 'ok' | 'error' | 'info'; texto: string } | null>(null);
  const [ocupado, setOcupado] = useState(false);
  const [manual, setManual] = useState('');

  const ubicaciones = catalogo?.ubicaciones ?? [];
  const precioDe = useCallback(
    (sku: string) => catalogo?.precios.find((p) => p.sku === sku)?.precio_venta ?? null,
    [catalogo],
  );

  const total = useMemo(
    () => cesta.reduce((s, l) => s + (precioDe(l.lote.sku) ?? 0) * l.uds, 0),
    [cesta, precioDe],
  );
  const hayPrecios = (catalogo?.precios.length ?? 0) > 0;

  const anotar = useCallback(
    async (tipo: string, datos: Record<string, unknown>, exito: string) => {
      setOcupado(true);
      try {
        const r = await registrar(tipo, { ...datos, operacionId: nuevaOperacionId() });
        setMensaje(
          r.bloqueadas > 0
            ? { tipo: 'error', texto: 'Guardado, pero el servidor lo ha rechazado. Míralo en Ajustes.' }
            : r.sinRed || r.fallidas > 0
              ? { tipo: 'info', texto: `${exito} · guardado en el móvil, se subirá al recuperar cobertura` }
              : { tipo: 'ok', texto: exito },
        );
        await subir();
      } finally {
        setOcupado(false);
      }
    },
    [subir],
  );

  const alLeer = useCallback(
    (texto: string) => {
      const lote = buscarLote(texto);
      if (!lote) {
        setMensaje({ tipo: 'error', texto: `No conozco el código «${texto}».` });
        return;
      }
      setUltimo(lote);
      setMensaje(null);

      switch (modo) {
        case 'CONSULTAR':
          break;

        case 'VENTA': {
          const disponible = saldoDe(lote.lote_id, ubicacion)?.disponible ?? 0;
          const yaEnCesta = cesta.find((l) => l.lote.lote_id === lote.lote_id)?.uds ?? 0;
          if (yaEnCesta + 1 > disponible) {
            setMensaje({
              tipo: 'error',
              texto: `Solo quedan ${disponible} de este lote en ${ubicacion.toLowerCase()}.`,
            });
            return;
          }
          setCesta((c) => {
            const i = c.findIndex((l) => l.lote.lote_id === lote.lote_id);
            if (i < 0) return [...c, { lote, uds: 1 }];
            const copia = [...c];
            copia[i] = { ...copia[i]!, uds: copia[i]!.uds + 1 };
            return copia;
          });
          break;
        }

        case 'ENTRADA':
        case 'SALIDA':
          void anotar('MOVIMIENTO', {
            tipo: modo, loteId: lote.lote_id, ubicacionId: ubicacion,
            cantidad: 1, ocurridoEn: ahora(),
          }, `${modo === 'ENTRADA' ? '+1' : '−1'} · ${lote.cafe}`);
          break;

        case 'TRASLADO':
          if (ubicacion === destino) {
            setMensaje({ tipo: 'error', texto: 'El origen y el destino son el mismo sitio.' });
            return;
          }
          void anotar('TRASLADO', {
            loteId: lote.lote_id, desde: ubicacion, hasta: destino,
            cantidad: 1, ocurridoEn: ahora(),
          }, `1 · ${ubicacion} → ${destino}`);
          break;

        case 'INVENTARIO':
          setCesta((c) => {
            const i = c.findIndex((l) => l.lote.lote_id === lote.lote_id);
            if (i < 0) return [...c, { lote, uds: 1 }];
            const copia = [...c];
            copia[i] = { ...copia[i]!, uds: copia[i]!.uds + 1 };
            return copia;
          });
          break;
      }
    },
    [modo, ubicacion, destino, cesta, buscarLote, saldoDe, anotar],
  );

  async function cobrar() {
    await anotar('VENTA', {
      ubicacionId: ubicacion,
      lineas: cesta.map((l) => ({
        sku: l.lote.sku, cantidad: l.uds, lote_id: l.lote.lote_id,
        ...(precioDe(l.lote.sku) !== null ? { precio_unit: precioDe(l.lote.sku) } : {}),
      })),
      canal: ubicacion === 'FURGONETA' ? 'Mercado' : 'Mostrador',
      origen: 'app',
      ocurridoEn: ahora(),
    }, `Venta registrada · ${cesta.reduce((s, l) => s + l.uds, 0)} paquetes`);
    setCesta([]);
  }

  async function cerrarRecuento() {
    await anotar('RECUENTO', {
      ubicacionId: ubicacion,
      recuento: cesta.map((l) => ({ lote_id: l.lote.lote_id, contado: l.uds })),
      ocurridoEn: ahora(),
      nota: 'Recuento con escáner',
    }, 'Recuento cerrado: se han generado los ajustes necesarios.');
    setCesta([]);
  }

  const modoActual = MODOS.find((m) => m.id === modo)!;
  const acumula = modo === 'VENTA' || modo === 'INVENTARIO';

  return (
    <main>
      <h1>Escanear</h1>
      <p className="sub">{modoActual.ayuda}</p>

      <div className="chips">
        {MODOS.map((m) => (
          <button
            key={m.id}
            className={m.id === modo ? 'on' : ''}
            onClick={() => { setModo(m.id); setCesta([]); setMensaje(null); }}
          >
            {m.texto}
          </button>
        ))}
      </div>

      <div style={{ display: 'flex', gap: '.6rem' }}>
        <label style={{ flex: 1 }}>
          {modo === 'TRASLADO' ? 'Desde' : 'Ubicación'}
          <select value={ubicacion} onChange={(e) => setUbicacion(e.target.value)}>
            {ubicaciones.map((u) => (
              <option key={u.ubicacion_id} value={u.ubicacion_id}>{u.nombre}</option>
            ))}
          </select>
        </label>
        {modo === 'TRASLADO' && (
          <label style={{ flex: 1 }}>
            Hasta
            <select value={destino} onChange={(e) => setDestino(e.target.value)}>
              {ubicaciones.map((u) => (
                <option key={u.ubicacion_id} value={u.ubicacion_id}>{u.nombre}</option>
              ))}
            </select>
          </label>
        )}
      </div>

      <Escaner onLeer={alLeer} />

      {mensaje && <div className={`aviso ${mensaje.tipo}`} style={{ marginTop: '.85rem' }}>{mensaje.texto}</div>}

      <form
        style={{ display: 'flex', gap: '.5rem', margin: '.85rem 0' }}
        onSubmit={(e) => { e.preventDefault(); if (manual.trim()) { alLeer(manual.trim()); setManual(''); } }}
      >
        <input
          value={manual} onChange={(e) => setManual(e.target.value.toUpperCase())}
          placeholder="…o escribe el código del lote" className="mono"
          style={{ marginTop: 0 }}
        />
        <button className="secundario" type="submit">Añadir</button>
      </form>

      {ultimo && !acumula && <FichaLote lote={ultimo} ubicacion={ubicacion} />}

      {acumula && cesta.length > 0 && (
        <>
          <h2>{modo === 'VENTA' ? 'Cesta' : 'Contado'}</h2>
          {cesta.map((l) => (
            <div key={l.lote.lote_id} className="tarjeta">
              <div className="fila">
                <strong>{l.lote.cafe}</strong>
                <span>{l.uds} {l.uds === 1 ? 'paquete' : 'paquetes'}</span>
              </div>
              <div className="fila">
                <span className="suave">{l.lote.formato}</span>
                {modo === 'INVENTARIO' && (
                  <span className="suave">
                    teórico {saldoDe(l.lote.lote_id, ubicacion)?.cantidad ?? 0}
                  </span>
                )}
                {modo === 'VENTA' && hayPrecios && precioDe(l.lote.sku) !== null && (
                  <span>{((precioDe(l.lote.sku) ?? 0) * l.uds).toFixed(2)} €</span>
                )}
              </div>
              <button
                className="secundario" style={{ marginTop: '.5rem', padding: '.3rem .7rem', minHeight: 36 }}
                onClick={() => setCesta((c) => c.filter((x) => x.lote.lote_id !== l.lote.lote_id))}
              >
                Quitar
              </button>
            </div>
          ))}

          {modo === 'VENTA' ? (
            <>
              {hayPrecios && (
                <div className="fila" style={{ margin: '.5rem 0 1rem', fontSize: '1.15rem' }}>
                  <strong>Total</strong><strong>{total.toFixed(2)} €</strong>
                </div>
              )}
              <button className="ancho" onClick={() => void cobrar()} disabled={ocupado}>
                {ocupado ? 'Guardando…' : 'Cobrar'}
              </button>
            </>
          ) : (
            <button className="ancho" onClick={() => void cerrarRecuento()} disabled={ocupado}>
              {ocupado ? 'Guardando…' : 'Cerrar recuento y ajustar'}
            </button>
          )}
        </>
      )}
    </main>
  );
}

function FichaLote({ lote, ubicacion }: { lote: LoteDetalle; ubicacion: string }) {
  const { catalogo } = useApp();
  const aqui = catalogo?.saldos.filter((s) => s.lote_id === lote.lote_id) ?? [];

  return (
    <div className="tarjeta">
      <div className="fila">
        <strong>{lote.cafe}</strong>
        <span className={`etiqueta ${lote.frescura}`}>
          {lote.dias_desde_tueste !== null ? `${lote.dias_desde_tueste} días` : 'sin fecha'}
        </span>
      </div>
      <div className="fila"><span className="suave">{lote.formato ?? lote.clase}</span></div>
      <div className="mono suave" style={{ marginTop: '.4rem' }}>{lote.lote_id}</div>
      <table style={{ marginTop: '.6rem' }}>
        <tbody>
          {aqui.map((s) => (
            <tr key={s.ubicacion_id}>
              <td style={{ fontWeight: s.ubicacion_id === ubicacion ? 600 : 400 }}>{s.ubicacion}</td>
              <td className="num">{s.cantidad}</td>
              <td className="num suave">{s.reservado > 0 ? `${s.reservado} res.` : ''}</td>
            </tr>
          ))}
          {aqui.length === 0 && <tr><td className="suave">Sin existencias en ningún sitio.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}
