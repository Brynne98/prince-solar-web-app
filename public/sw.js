// Pop-up alerts (SOLAR-244). Registered only when someone turns pop-ups on in
// Account > Notifications. It shows the pop-up notify sends and opens the app on a tap.
// No fetch handler: the app loads from the network as it always has.
// Kept at the site root, not in /build: a worker's scope is its folder, and /build
// files are cached for a year.

// A new version takes over at once (it caches nothing, so nothing can go stale), and
// takes the open app over, so a tap can steer it without a reload first.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('push', (e) => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch (err) { /* not ours */ }
  if (!m.title) return;
  e.waitUntil(self.registration.showNotification(m.title, {
    body: m.body, tag: m.tag, data: m.data || {},
    icon: '/icon-192.png', badge: '/icon-192.png',
  }));
});

// data is {id, tab, plant, day}: the page, plant and day to open, and the alert to mark read.
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const d = e.notification.data || {};
  const url = new URL('/', self.location.origin);
  if (d.tab) url.searchParams.set('tab', d.tab);
  if (d.plant) url.searchParams.set('plant', d.plant);
  if (d.day) url.searchParams.set('day', d.day);
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
