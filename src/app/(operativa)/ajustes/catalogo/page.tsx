'use client';

/**
 * Catálogo: cafés, formatos, referencias y precios.
 *
 * Los cuatro están separados a propósito, porque son cosas distintas:
 * un café es el grano, un formato es el envase, y una referencia es la
 * combinación concreta que se vende y que lleva su propio EAN.
 */
import { useState } from 'react';
import Link from 'next/link';
import { Editor } from '@/componentes/Editor';
import { EanDeArticulo } from '@/componentes/Ean';
import { Capacidad } from '@/componentes/Capacidad';

type Pestana = 'cafes' | 'formatos' | 'articulos' | 'precios' | 'ubicaciones' | 'cajas';

const PESTANAS: { id: Pestana; texto: string }[] = [
  { id: 'cafes', texto: 'Cafés' },
  { id: 'formatos', texto: 'Formatos' },
  { id: 'articulos', texto: 'Referencias' },
  { id: 'precios', texto: 'Precios' },
  { id: 'ubicaciones', texto: 'Ubicaciones' },
  { id: 'cajas', texto: 'Cajas' },
];

export default function Catalogo() {
  const [pestana, setPestana] = useState<Pestana>('cafes');

  return (
    <>
      <div style={{ padding: '1rem 1rem 0', maxWidth: '46rem', margin: '0 auto' }}>
        <div className="chips">
          {PESTANAS.map((p) => (
            <button key={p.id} className={pestana === p.id ? 'on' : ''}
                    onClick={() => setPestana(p.id)}>
              {p.texto}
            </button>
          ))}
        </div>
      </div>

      {pestana === 'cafes' && (
        <Editor
          recurso="cafes" clave="cafe_id"
          titulo="Cafés" vacia={{ activo: true }}
          descripcion="El grano, sin envasar. El código corto viaja dentro del QR de la etiqueta."
          campos={[
            { nombre: 'cafe_id', etiqueta: 'Código corto', tipo: 'texto', requerido: true,
              soloAlta: true, ayuda: 'ETHYIR, COLHUI… no se puede cambiar después' },
            { nombre: 'nombre', etiqueta: 'Nombre completo', tipo: 'texto', requerido: true },
            { nombre: 'origen', etiqueta: 'Origen', tipo: 'texto' },
            { nombre: 'variedad', etiqueta: 'Variedad', tipo: 'texto' },
            { nombre: 'proceso', etiqueta: 'Proceso', tipo: 'texto' },
            { nombre: 'altitud', etiqueta: 'Altitud', tipo: 'texto' },
            { nombre: 'perfil_tueste', etiqueta: 'Perfil de tueste', tipo: 'texto' },
            { nombre: 'notas_cata', etiqueta: 'Notas de cata', tipo: 'area' },
            { nombre: 'activo', etiqueta: 'Activo', tipo: 'siNo' },
          ]}
          resumen={(f) => (
            <>
              <div className="fila">
                <strong>{String(f.nombre)}</strong>
                {f.activo === false && <span className="etiqueta SIN_FECHA">de baja</span>}
              </div>
              <div className="fila">
                <span className="mono suave">{String(f.cafe_id)}</span>
                <span className="suave">{[f.origen, f.perfil_tueste].filter(Boolean).join(' · ')}</span>
              </div>
            </>
          )}
        />
      )}

      {pestana === 'formatos' && (
        <Editor
          recurso="formatos" clave="formato_id"
          titulo="Formatos" vacia={{ activo: true, molienda: 'GRANO' }}
          descripcion="Los tamaños en que se envasa. Los gramos se usan para calcular la merma del tueste."
          campos={[
            { nombre: 'formato_id', etiqueta: 'Código', tipo: 'texto', requerido: true,
              soloAlta: true, ayuda: 'F250G, F1KG…' },
            { nombre: 'nombre', etiqueta: 'Cómo se llama', tipo: 'texto', requerido: true,
              ayuda: 'lo que se lee en la etiqueta' },
            { nombre: 'gramos', etiqueta: 'Gramos de café', tipo: 'numero', requerido: true,
              paso: '1', ayuda: 'peso neto real' },
            { nombre: 'molienda', etiqueta: 'Molienda', tipo: 'lista', requerido: true,
              opciones: [{ valor: 'GRANO', texto: 'Grano' }, { valor: 'MOLIDO', texto: 'Molido' }] },
            { nombre: 'activo', etiqueta: 'Activo', tipo: 'siNo' },
          ]}
          resumen={(f) => (
            <div className="fila">
              <strong>{String(f.nombre)}</strong>
              <span className="suave">{String(f.gramos)} g · {String(f.molienda).toLowerCase()}</span>
            </div>
          )}
        />
      )}

      {pestana === 'articulos' && (
        <Editor
          recurso="articulos" clave="sku"
          titulo="Referencias" vacia={{ activo: true, clase: 'PAQUETE' }}
          descripcion="Lo que se mueve en el inventario. Un café verde, y cada combinación de café y formato que se vende."
          campos={[
            { nombre: 'sku', etiqueta: 'SKU', tipo: 'texto', requerido: true, soloAlta: true,
              ayuda: 'ETHYIR-F250G, VRD-ETHYIR…' },
            { nombre: 'clase', etiqueta: 'Qué es', tipo: 'lista', requerido: true,
              opciones: [
                { valor: 'PAQUETE', texto: 'Paquete terminado (se vende)' },
                { valor: 'VERDE', texto: 'Café verde (se compra)' },
                { valor: 'GRANEL', texto: 'Tostado a granel' },
              ] },
            { nombre: 'cafe_id', etiqueta: 'Café', tipo: 'texto', requerido: true,
              ayuda: 'el código corto del café' },
            { nombre: 'formato_id', etiqueta: 'Formato', tipo: 'texto',
              ayuda: 'solo para paquetes; el verde va en kilos' },
            { nombre: 'activo', etiqueta: 'Activo', tipo: 'siNo' },
          ]}
          resumen={(f) => (
            <>
              <div className="fila">
                <strong className="mono">{String(f.sku)}</strong>
                <span className="suave">{String(f.clase).toLowerCase()}</span>
              </div>
              <div className="fila">
                <span className="suave">
                  {String(f.cafe_id)}{f.formato_id ? ` · ${String(f.formato_id)}` : ''}
                </span>
                <span className="mono suave">{f.ean13 ? String(f.ean13) : 'sin EAN'}</span>
              </div>
            </>
          )}
          extra={(f, recargar) =>
            f.clase === 'PAQUETE'
              ? <EanDeArticulo sku={String(f.sku)} ean={f.ean13 as string | null} alCambiar={recargar} />
              : null}
        />
      )}

      {pestana === 'precios' && (
        <Editor
          recurso="precios" clave="sku"
          titulo="Precios y mínimos" vacia={{}}
          descripcion="Una fila por referencia que se vende de verdad. Sin coste, el margen no se puede calcular."
          campos={[
            { nombre: 'sku', etiqueta: 'SKU', tipo: 'texto', requerido: true, soloAlta: true },
            { nombre: 'precio_venta', etiqueta: 'Precio de venta sin IVA', tipo: 'numero', paso: '0.01' },
            { nombre: 'coste_unitario', etiqueta: 'Coste por paquete', tipo: 'numero', paso: '0.01',
              ayuda: 'verde + merma + bolsa + etiqueta + válvula' },
            { nombre: 'stock_minimo', etiqueta: 'Stock mínimo', tipo: 'numero', paso: '1' },
            { nombre: 'stock_objetivo', etiqueta: 'Stock objetivo', tipo: 'numero', paso: '1' },
          ]}
          resumen={(f) => (
            <>
              <div className="fila">
                <strong className="mono">{String(f.sku)}</strong>
                <strong>{f.precio_venta ? `${Number(f.precio_venta).toFixed(2)} €` : 'sin precio'}</strong>
              </div>
              <div className="fila">
                <span className="suave">
                  coste {f.coste_unitario ? `${Number(f.coste_unitario).toFixed(2)} €` : '—'}
                </span>
                <span className="suave">mínimo {f.stock_minimo === null || f.stock_minimo === undefined ? "—" : String(f.stock_minimo)}</span>
              </div>
            </>
          )}
        />
      )}

      {pestana === 'ubicaciones' && (
        <Editor
          recurso="ubicaciones" clave="ubicacion_id"
          titulo="Ubicaciones" vacia={{ activo: true, tipo: 'PROPIA', politica_lote: 'LOTE_ACTIVO', permite_venta: true }}
          descripcion="Dónde puede estar el café. El depósito de un tercero es una ubicación más, con su propio saldo."
          campos={[
            { nombre: 'ubicacion_id', etiqueta: 'Código', tipo: 'texto', requerido: true, soloAlta: true },
            { nombre: 'nombre', etiqueta: 'Nombre', tipo: 'texto', requerido: true },
            { nombre: 'tipo', etiqueta: 'Tipo', tipo: 'lista', requerido: true,
              opciones: [
                { valor: 'PROPIA', texto: 'Propia (almacén, tienda, furgoneta)' },
                { valor: 'DEPOSITO', texto: 'Depósito en casa ajena' },
                { valor: 'TRANSITO', texto: 'En reparto' },
              ] },
            { nombre: 'politica_lote', etiqueta: 'De qué lote sale', tipo: 'lista', requerido: true,
              opciones: [
                { valor: 'LOTE_ACTIVO', texto: 'El repuesto por el último escaneo' },
                { valor: 'FIFO', texto: 'El más antiguo con saldo' },
              ] },
            { nombre: 'permite_venta', etiqueta: '¿Se vende desde aquí?', tipo: 'siNo' },
            { nombre: 'activo', etiqueta: 'Activa', tipo: 'siNo' },
            { nombre: 'notas', etiqueta: 'Notas', tipo: 'area' },
          ]}
          resumen={(f) => (
            <>
              <div className="fila">
                <strong>{String(f.nombre)}</strong>
                <span className="suave">{String(f.tipo).toLowerCase()}</span>
              </div>
              <div className="fila">
                <span className="mono suave">{String(f.ubicacion_id)}</span>
                <span className="suave">
                  {f.permite_venta ? 'se vende' : 'solo traslados'}
                  {' · '}{String(f.politica_lote).toLowerCase().replace('_', ' ')}
                </span>
              </div>
            </>
          )}
        />
      )}

      {pestana === 'cajas' && (
        <Editor
          recurso="cajas" clave="caja_id"
          titulo="Cajas" vacia={{ activo: true, peso_vacio_g: 0 }}
          descripcion="Los tamaños que se usan para enviar. El peso en vacío evita tener que pesar cada bulto."
          campos={[
            { nombre: 'caja_id', etiqueta: 'Código', tipo: 'texto', requerido: true, soloAlta: true },
            { nombre: 'nombre', etiqueta: 'Nombre', tipo: 'texto', requerido: true },
            { nombre: 'largo_cm', etiqueta: 'Largo (cm)', tipo: 'numero', requerido: true, paso: '0.1' },
            { nombre: 'ancho_cm', etiqueta: 'Ancho (cm)', tipo: 'numero', requerido: true, paso: '0.1' },
            { nombre: 'alto_cm', etiqueta: 'Alto (cm)', tipo: 'numero', requerido: true, paso: '0.1' },
            { nombre: 'peso_vacio_g', etiqueta: 'Peso en vacío (g)', tipo: 'numero', requerido: true, paso: '1' },
            { nombre: 'activo', etiqueta: 'Activa', tipo: 'siNo' },
          ]}
          resumen={(f) => (
            <>
              <div className="fila">
                <strong>{String(f.nombre)}</strong>
                <span className="suave">
                  {String(f.largo_cm)} × {String(f.ancho_cm)} × {String(f.alto_cm)} cm
                </span>
              </div>
              <div className="fila">
                <span className="mono suave">{String(f.caja_id)}</span>
                <span className="suave">vacía {String(f.peso_vacio_g)} g</span>
              </div>
            </>
          )}
          extra={(f) => <Capacidad cajaId={String(f.caja_id)} />}
        />
      )}

      <p className="suave" style={{ padding: '0 1rem 2rem', maxWidth: '46rem', margin: '0 auto' }}>
        <Link href="/ajustes">← Ajustes</Link>
      </p>
    </>
  );
}
