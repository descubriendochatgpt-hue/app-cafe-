'use client';

/**
 * Impresión de etiquetas.
 *
 * Dos botones al final y no uno, a propósito: en iPhone y con la app
 * instalada, descargar un PDF a menudo no hace nada visible. «Abrir e
 * imprimir» lo abre en una pestaña, que es lo que funciona ahí.
 */
import { useEffect, useMemo, useState } from 'react';
import { useApp } from '@/componentes/Estado';
import {
  generarEtiquetas, eanValido, PAPELES, GS1_MIN,
  type TipoEtiqueta, type Resultado,
} from '@/lib/etiquetas';

export default function Etiquetas() {
  const { catalogo } = useApp();
  const [loteId, setLoteId] = useState('');
  const [tipo, setTipo] = useState<TipoEtiqueta>('PROPIA');
  const [papelId, setPapelId] = useState('A4-70x37');
  const [cantidad, setCantidad] = useState('24');
  const [saltar, setSaltar] = useState('0');
  const [resultado, setResultado] = useState<Resultado | null>(null);
  const [url, setUrl] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [generando, setGenerando] = useState(false);

  const papel = PAPELES.find((p) => p.id === papelId)!;
  const lotes = useMemo(
    () => (catalogo?.lotes ?? []).filter((l) => l.clase === 'PAQUETE'),
    [catalogo],
  );
  const lote = lotes.find((l) => l.lote_id === loteId);
  const sinEan = tipo === 'ECI' && !eanValido(lote?.ean13);

  // El objeto URL se revoca al cambiar: si no, cada generación deja un PDF
  // colgado en memoria y una feria son muchas generaciones.
  useEffect(() => () => { if (url) URL.revokeObjectURL(url); }, [url]);

  async function generar() {
    if (!lote) return;
    setGenerando(true);
    setError(null);
    try {
      const r = await generarEtiquetas({
        datos: {
          loteId: lote.lote_id,
          cafe: lote.cafe,
          origen: lote.origen,
          formato: lote.formato,
          gramos: lote.gramos,
          molienda: lote.molienda,
          fechaTostado: lote.fecha_tostado,
          consumoPreferente: lote.fecha_consumo_preferente,
          ean13: lote.ean13,
        },
        tipo,
        papel,
        cantidad: Math.max(1, Number(cantidad) || 1),
        saltar: Math.max(0, Number(saltar) || 0),
        empresa: catalogo?.parametros?.nombre_empresa,
        textoLegal: catalogo?.parametros?.texto_legal_etiqueta || undefined,
      });
      if (url) URL.revokeObjectURL(url);
      setUrl(URL.createObjectURL(r.blob));
      setResultado(r);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'No se pudo generar el PDF.');
      setResultado(null);
    } finally {
      setGenerando(false);
    }
  }

  return (
    <main>
      <h1>Etiquetas</h1>
      <p className="sub">
        El QR identifica el <strong>lote</strong> y cambia con cada tueste. El EAN-13
        identifica el <strong>producto</strong> y no cambia nunca.
      </p>

      <div className="chips">
        {([['PROPIA', 'Venta propia'], ['ECI', 'El Corte Inglés']] as const).map(([id, texto]) => (
          <button key={id} className={tipo === id ? 'on' : ''}
                  onClick={() => { setTipo(id); setResultado(null); }}>
            {texto}
          </button>
        ))}
      </div>

      <label>
        Lote
        <select value={loteId} onChange={(e) => { setLoteId(e.target.value); setResultado(null); }}>
          <option value="">Elige…</option>
          {lotes.map((l) => (
            <option key={l.lote_id} value={l.lote_id}>
              {l.cafe} · {l.formato} · {l.fecha_tostado} · {l.stock_total} uds
            </option>
          ))}
        </select>
      </label>

      {sinEan && (
        <div className="aviso error">
          Esta referencia no tiene un EAN-13 válido. Hay que asignarlo antes de imprimir
          para El Corte Inglés: sus cajas no leen el QR interno.
        </div>
      )}

      <label>
        Papel
        <select value={papelId} onChange={(e) => { setPapelId(e.target.value); setResultado(null); }}>
          {PAPELES.map((p) => <option key={p.id} value={p.id}>{p.nombre}</option>)}
        </select>
      </label>

      <div style={{ display: 'flex', gap: '.6rem' }}>
        <label style={{ flex: 1 }}>
          Cuántas
          <input type="number" min="1" inputMode="numeric"
                 value={cantidad} onChange={(e) => setCantidad(e.target.value)} />
        </label>
        {!papel.rollo && (
          <label style={{ flex: 1 }}>
            Huecos ya usados
            <input type="number" min="0" max={papel.columnas * papel.filas - 1} inputMode="numeric"
                   value={saltar} onChange={(e) => setSaltar(e.target.value)} />
          </label>
        )}
      </div>
      {!papel.rollo && (
        <p className="suave" style={{ marginTop: '-.4rem' }}>
          {papel.columnas * papel.filas} por hoja. Los huecos ya usados se saltan para
          aprovechar una hoja empezada.
        </p>
      )}

      {error && <div className="aviso error">{error}</div>}

      <button className="ancho" onClick={() => void generar()}
              disabled={!lote || sinEan || generando}>
        {generando ? 'Generando…' : 'Generar PDF'}
      </button>

      {resultado && url && (
        <div className="tarjeta" style={{ marginTop: '1rem' }}>
          <div className="fila">
            <strong>{resultado.paginas} {resultado.paginas === 1 ? 'página' : 'páginas'}</strong>
            {resultado.escalaEan !== null && (
              <span className={`etiqueta ${resultado.escalaEan < GS1_MIN ? 'CRITICO' : 'FRESCO'}`}>
                código al {Math.round(resultado.escalaEan * 100)} %
              </span>
            )}
          </div>

          {resultado.aviso && <div className="aviso error" style={{ marginTop: '.6rem' }}>{resultado.aviso}</div>}

          {resultado.escalaEan !== null && !resultado.aviso && (
            <p className="suave" style={{ margin: '.5rem 0 0' }}>
              Dentro del 80-200 % que permite la norma GS1. Aun así, antes de la primera
              entrega, pasa una etiqueta impresa por un lector de verdad: el papel satinado
              y la tinta justa emborronan las barras.
            </p>
          )}

          <div style={{ display: 'flex', gap: '.5rem', marginTop: '.85rem' }}>
            <a href={url} download={`etiquetas-${loteId}.pdf`} style={{ flex: 1 }}>
              <button className="ancho secundario" type="button">Descargar</button>
            </a>
            <button className="ancho" style={{ flex: 1 }}
                    onClick={() => window.open(url, '_blank')}>
              Abrir e imprimir
            </button>
          </div>
          <p className="suave" style={{ margin: '.6rem 0 0' }}>
            En iPhone y con la app instalada, «Descargar» a menudo no hace nada:
            usa «Abrir e imprimir».
          </p>

          <iframe
            src={url} title="Vista previa"
            style={{
              width: '100%', height: 420, marginTop: '.85rem', border: '1px solid var(--borde)',
              borderRadius: 8, background: '#fff',
            }}
          />
        </div>
      )}
    </main>
  );
}
