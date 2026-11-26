// Pop-up alerts (SOLAR-244) and the offline page (SOLAR-592). Every app load registers it
// (app.jsx); pop-ups still start only when someone turns them on in Account > Notifications.
// It shows the pop-up notify sends and opens the app on a tap.
// Kept at the site root, not in /build: a worker's scope is its folder, and /build
// files are cached for a year.

// The offline page (SOLAR-592): the only thing kept. Pages load from the network as they
// always have; only when that fails is a page load answered with offline.html. The app,
// its scripts, Supabase and every other request are never touched.
// OFFLINE is the kept copy's name. Cloudflare's build stamps it with a hash of the three
// files (vite.config.mjs), so a change to any of them changes this file, the browser
// installs the new worker, and activate drops the old copy.
const OFFLINE = 'offline-dev';
const OFFLINE_FILES = ['/offline.html', '/offline.js', '/theme.js'];

// A new version takes over at once, and takes the open app over, so a tap can steer it
// without a reload first.
self.addEventListener('install', (e) => e.waitUntil((async () => {
  const c = await caches.open(OFFLINE);
  // past the browser's own cache, so the copy kept is the one just pushed
  await c.addAll(OFFLINE_FILES.map((u) => new Request(u, { cache: 'reload' })));
  await self.skipWaiting();
})()));
self.addEventListener('activate', (e) => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k !== OFFLINE) await caches.delete(k);
  await self.clients.claim();
})()));

self.addEventListener('fetch', (e) => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const url = new URL(r.url);
  // a page load that fails: the offline page, at the address asked for
  if (r.mode === 'navigate') {
    // A fresh Response: Cloudflare (and serve) redirect /offline.html to /offline, and the
    // browser refuses a redirected answer to a page load.
    e.respondWith(fetch(r).catch(async () => {
      const kept = await caches.match('/offline.html', { cacheName: OFFLINE });
      return kept ? new Response(kept.body, kept) : Response.error();
    }));
    return;
  }
  // the offline page's own two files, from the copy only when the network fails
  if (url.origin === self.location.origin && OFFLINE_FILES.includes(url.pathname) && url.pathname !== '/offline.html') {
    e.respondWith(fetch(r).catch(() => caches.match(url.pathname, { cacheName: OFFLINE })));
  }
});

self.addEventListener('push', (e) => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch (err) { /* not ours */ }
  if (!m.title) return;
  e.waitUntil(self.registration.showNotification(m.title, {
    body: m.body, tag: m.tag, data: m.data || {},
    icon: '/icon-192.png', badge: '/icon-192.png',
  }));
});

// data is {id, tab, plant, day, section}: the page, plant, day and Settings section to open,
// and the alert to mark read.
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const d = e.notification.data || {};
  const url = new URL('/', self.location.origin);
  if (d.tab) url.searchParams.set('tab', d.tab);
  if (d.plant) url.searchParams.set('plant', d.plant);
  if (d.day) url.searchParams.set('day', d.day);
  if (d.section) url.searchParams.set('section', d.section);
  if (d.id) url.searchParams.set('opened', d.id);
  e.waitUntil((async () => {
    const open = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const tab = open.find((c) => new URL(c.url).origin === self.location.origin);
    if (tab) {
      // navigate first: focus can be refused, and must not stop the app opening the alert
      try { const t = await tab.navigate(url.href); await (t || tab).focus().catch(() => {}); return; }
      catch (err) { /* not ours to steer: a new window */ }
    }
    return self.clients.openWindow(url.href);
  })());
});
