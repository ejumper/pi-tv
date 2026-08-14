const CACHE = 'remote-v3';
const ASSETS = [
    '/',
    '/style.css',
    '/remote.js',
    '/icons/arrows.svg',
    '/icons/enter.svg',
    '/icons/escape.svg',
    '/icons/home.svg',
    '/icons/menu.svg',
    '/icons/power.svg',
    '/icons/tab.svg',
];

self.addEventListener('install', e => {
    e.waitUntil(
        caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting())
    );
});

self.addEventListener('activate', e => {
    e.waitUntil(
        caches.keys().then(keys =>
            Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
        ).then(() => self.clients.claim())
    );
});

// Cache-first for assets, network-only for API calls
self.addEventListener('fetch', e => {
    if (e.request.url.includes('/api/')) return;
    e.respondWith(
        caches.match(e.request).then(cached => cached || fetch(e.request))
    );
});
