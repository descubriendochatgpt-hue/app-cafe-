'use client';

import Link from 'next/link';
import { Editor } from '@/componentes/Editor';

export default function Clientes() {
  return (
    <>
      <Editor
        recurso="clientes" clave="cliente_id"
        titulo="Clientes" vacia={{ activo: true, tipo: 'Particular', pais: 'España', descuento_pct: 0 }}
        descripcion="El tipo decide cómo se reparte la facturación en los informes. Los de hostelería son los que pueden tener enlace de pedido."
        campos={[
          { nombre: 'nombre', etiqueta: 'Nombre o razón social', tipo: 'texto', requerido: true },
          { nombre: 'tipo', etiqueta: 'Tipo', tipo: 'lista', requerido: true,
            opciones: ['Particular', 'Hostelería', 'Tienda', 'Online', 'Distribuidor']
              .map((t) => ({ valor: t, texto: t })) },
          { nombre: 'nif', etiqueta: 'NIF / CIF', tipo: 'texto',
            ayuda: 'necesario para poder facturarle' },
          { nombre: 'email', etiqueta: 'Email', tipo: 'texto' },
          { nombre: 'telefono', etiqueta: 'Teléfono', tipo: 'texto',
            ayuda: 'con prefijo, para el enlace de WhatsApp' },
          { nombre: 'direccion', etiqueta: 'Dirección', tipo: 'texto' },
          { nombre: 'cp', etiqueta: 'Código postal', tipo: 'texto' },
          { nombre: 'poblacion', etiqueta: 'Población', tipo: 'texto' },
          { nombre: 'provincia', etiqueta: 'Provincia', tipo: 'texto' },
          { nombre: 'descuento_pct', etiqueta: 'Descuento habitual (%)', tipo: 'numero', paso: '0.5' },
          { nombre: 'activo', etiqueta: 'Activo', tipo: 'siNo' },
          { nombre: 'notas', etiqueta: 'Notas', tipo: 'area' },
        ]}
        resumen={(f) => (
          <>
            <div className="fila">
              <strong>{String(f.nombre)}</strong>
              <span className="suave">{String(f.tipo)}</span>
            </div>
            <div className="fila">
              <span className="suave">{[f.poblacion, f.nif].filter(Boolean).join(' · ') || '—'}</span>
              {Number(f.descuento_pct) > 0 && (
                <span className="suave">{String(f.descuento_pct)}% dto.</span>
              )}
            </div>
          </>
        )}
      />
      <p className="suave" style={{ padding: '0 1rem 2rem', maxWidth: '46rem', margin: '0 auto' }}>
        <Link href="/ajustes/hosteleria">Enlaces de pedido →</Link>{' · '}
        <Link href="/ajustes">Ajustes</Link>
      </p>
    </>
  );
}
