// Dark, Light or the device's (SOLAR-318). Runs in <head> before the page paints, so a
// light choice never flashes dark. The choice is kept per device in localStorage
// ('dark' | 'light' | 'device'; nothing saved = 'device'). Settings calls window.setTheme.
(function () {
  var KEY = 'ps-theme';
  var media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: light)') : null;
  var picked = null; // this page's pick, for a browser that won't store it
  function saved() {
    if (picked) return picked;
    try { var v = localStorage.getItem(KEY); return v === 'dark' || v === 'light' ? v : 'device'; } catch (e) { return 'device'; }
  }
  function apply() {
    var choice = saved();
    var mode = choice === 'device' ? (media && media.matches ? 'light' : 'dark') : choice;
    document.documentElement.setAttribute('data-theme', mode);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', mode === 'light' ? '#eaedf2' : '#0a0d12'); // --bg of each
    window.dispatchEvent(new Event('ps-theme'));
  }
  window.getTheme = saved;
  window.setTheme = function (choice) {
    picked = choice;
    try { if (choice === 'device') localStorage.removeItem(KEY); else localStorage.setItem(KEY, choice); } catch (e) {}
    apply();
  };
  if (media && media.addEventListener) media.addEventListener('change', apply);
  // another tab on this device changed it
  window.addEventListener('storage', function (e) { if (e.key === KEY) { picked = null; apply(); } });
  apply();
})();
