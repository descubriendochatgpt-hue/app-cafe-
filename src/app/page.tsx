/**
 * Marcador de posición. La PWA completa (escáner, etiquetas, cola offline)
 * es la fase 2; esta fase entrega el núcleo y su API.
 */
export default function Inicio() {
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', maxWidth: '40rem' }}>
      <h1>Gestión de tueste y stock</h1>
      <p>
        Núcleo de inventario operativo. La interfaz de almacén llega en la fase 2.
      </p>
      <ul>
        <li><code>POST /api/auth/login</code> — identificación por PIN</li>
        <li><code>POST /api/operaciones</code> — subida de operaciones (una o en lote)</li>
        <li><code>GET /api/stock</code> — stock consolidado por artículo y ubicación</li>
      </ul>
    </main>
  );
}
