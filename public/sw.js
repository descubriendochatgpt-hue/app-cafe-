/* Service worker.
 *
 * Guarda el armazón de la aplicación para que abra sin cobertura. Lo que NO
 * hace es cachear peticiones a la API: los datos viven en IndexedDB, que es
 * quien sabe distinguir entre «esto ya se subió» y «esto sigue pendiente».
 * Un caché de respuestas aquí solo serviría para enseñar stock viejo como si
 * fuera bueno.
 */
const VERSION = 'cafe-v1';
const ARMAZON = ['/', '/escanear', '/stock', '/tueste', '/ajustes', '/manifest.webmanifest'];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(VERSION)
      .then((c) => c.addAll(ARMAZON).catch(() => undefined))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((ks) => Promise.all(ks.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);

  // Nada de la API se cachea, y las escrituras menos todavía.
  if (e.request.method !== 'GET' || url.pathname.startsWith('/api/')) return;
  if (url.origin !== self.location.origin) return;

  // Red primero, caché como red de seguridad: mientras haya cobertura se ve
  // siempre la versión buena.
  e.respondWith(
    fetch(e.request)
      .then((r) => {
        const copia = r.clone();
        caches.open(VERSION).then((c) => c.put(e.request, copia)).catch(() => undefined);
        return r;
      })
      .catch(() => caches.match(e.request).then((r) => r || caches.match('/escanear'))),
  );
});
