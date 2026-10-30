// Ferents Team Training — сервіс-воркер: додаток відкривається без інтернету
// і завжди бере свіжу версію сайту, коли інтернет є.
const VERSION = 'ft-v3.23';
const SHELL = ['./', 'index.html', 'manifest.webmanifest', 'icons/karate-192.png', 'icons/karate-512.png', 'icons/karate-apple-180.png', 'fonts/manrope.woff'];
const SUPABASE_LIB = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2';

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll([...SHELL, SUPABASE_LIB])).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys()
    .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

// Спершу мережа (свіжі дані), а без інтернету — збережена копія
async function networkFirst(req, opts) {
  const cache = await caches.open(VERSION);
  try {
    const res = await fetch(req, opts);
    if (res.ok) cache.put(req, res.clone());
    return res;
  } catch (err) {
    const hit = await cache.match(req, { ignoreSearch: req.mode === 'navigate' });
    if (hit) return hit;
    if (req.mode === 'navigate') return cache.match('index.html');
    throw err;
  }
}

// Спершу збережена копія, а в фоні оновлюємо (для бібліотеки Supabase)
async function cacheFirst(req) {
  const cache = await caches.open(VERSION);
  const hit = await cache.match(req);
  const fresh = fetch(req).then(res => { if (res.ok) cache.put(req, res.clone()); return res; }).catch(() => null);
  return hit || (await fresh) || Response.error();
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.searchParams.has('check')) return; // перевірка нової версії — завжди напряму з мережі

  // Сторінка сайту: завжди перевіряємо, чи є нова версія
  if (req.mode === 'navigate') { e.respondWith(networkFirst(req, { cache: 'no-cache' })); return; }
  // Файли сайту (іконки, manifest)
  if (url.origin === location.origin) { e.respondWith(networkFirst(req, { cache: 'no-cache' })); return; }
  // Бібліотека Supabase з CDN
  if (url.href.startsWith('https://cdn.jsdelivr.net/npm/@supabase/')) { e.respondWith(cacheFirst(req)); return; }
  // Дані з бази (читання): без інтернету показуємо останні збережені
  if (url.hostname.endsWith('.supabase.co') && url.pathname.startsWith('/rest/v1/')) {
    e.respondWith(networkFirst(req));
  }
});

// ===== Сповіщення на телефон =====
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { title: 'Ferents Team', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Ferents Team', {
    body: d.body || '',
    icon: 'icons/karate-192.png',
    badge: 'icons/karate-192.png',
    tag: d.tag || undefined,
    renotify: !!d.tag,
    data: { url: d.url || './' },
  }));
});

// Натиснули на сповіщення — відкриваємо застосунок на потрібній сторінці
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const target = new URL(e.notification.data && e.notification.data.url || './', self.registration.scope).href;
  e.waitUntil((async () => {
    const wins = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) {
      if (w.url.startsWith(self.registration.scope)) { await w.focus(); try { await w.navigate(target); } catch (err) {} return; }
    }
    await clients.openWindow(target);
  })());
});
