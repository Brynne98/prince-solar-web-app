// The offline page (SOLAR-592). A file, not inline: the site's CSP allows only 'self' scripts.
// The app saves its last reading's time as it reads (app.jsx loadLive); shown the way the
// cards show it: the time, and the date once it is over a day and a half old.
(() => {
  let last = null;
  try { last = JSON.parse(localStorage.getItem('ps.lastReading')); } catch (e) {}
  if (last && last.t) {
    const d = new Date(last.t), tz = last.tz || undefined;
    const time = (o) => { try { return d.toLocaleString('en-GB', { ...o, timeZone: tz }); } catch (e) { return d.toLocaleString('en-GB', o); } };
    const hm = time({ hour: '2-digit', minute: '2-digit' });
    document.getElementById('last').textContent = 'Last reading '
      + (Date.now() - last.t > 36 * 3600e3 ? time({ day: 'numeric', month: 'short' }) + ', ' + hm : hm);
  }
  // the address that failed: the app, at the tab it was asked for
  document.getElementById('again').addEventListener('click', () => location.reload());
  // back online: load the app on its own
  addEventListener('online', () => location.reload());
})();
