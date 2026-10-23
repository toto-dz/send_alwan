
const CACHE_NAME = 'print-service-v3';
const BASE_PATH = '/send_alwan/';

const APP_FILES = [
  BASE_PATH,
  `${BASE_PATH}index.html`,
  `${BASE_PATH}manifest.json`,
  `${BASE_PATH}icon-192.svg`,
  `${BASE_PATH}icon-512.svg`
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(APP_FILES))
  );

  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(
        keys
          .filter(key => key.startsWith('print-service-') && key !== CACHE_NAME)
          .map(key => caches.delete(key))
      )
    )
  );

  self.clients.claim();
});

self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;

  const url = new URL(event.request.url);

  if (url.origin !== self.location.origin) return;
  if (!url.pathname.startsWith(BASE_PATH)) return;

  event.respondWith(
    fetch(event.request).then(response => {
      if (response.ok) {
        const copy = response.clone();

        caches.open(CACHE_NAME).then(cache =>
          cache.put(event.request, copy)
        );
      }

      return response;
    }).catch(async () => {
      const cached = await caches.match(event.request);

      if (cached) return cached;

      // الصفحة الرئيسية فقط، وليس كل الملفات
      if (
        url.pathname === BASE_PATH ||
        url.pathname === `${BASE_PATH}index.html`
      ) {
        const home = await caches.match(`${BASE_PATH}index.html`);
        if (home) return home;
      }

      return new Response('غير متاح دون اتصال بالإنترنت', {
        status: 503,
        headers: { 'Content-Type': 'text/plain; charset=utf-8' }
      });
    })
  );
});
