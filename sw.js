const CACHE_NAME = 'print-service-v9';
const APP_FILES = ['./index.html', './manifest.json', './logo-alwan.svg', './alwan.png', './printing-background.png', './icon-192.svg?v=2', './icon-512.svg?v=2'];

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(APP_FILES)));
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key)))));
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;
  event.respondWith(fetch(event.request).then(response => {
    if (response.ok) {
      const copy = response.clone();
      caches.open(CACHE_NAME).then(cache => cache.put(event.request, copy));
    }
    return response;
  }).catch(() => caches.match(event.request).then(cached => cached || caches.match('./index.html'))));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(windows => {
    const appWindow=windows.find(client => new URL(client.url).origin===self.location.origin);
    if(appWindow)return appWindow.focus();
    return self.clients.openWindow(event.notification.data?.url||'./index.html');
  }));
});
