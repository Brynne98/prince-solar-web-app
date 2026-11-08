// Dark, Light or the device's (SOLAR-318). Runs in <head> before the page paints, so a
// light choice never flashes dark. The choice is kept per device in localStorage
// ('dark' | 'light' | 'device'; nothing saved = 'device'). Settings calls window.setTheme.
(function () {
  var KEY = 'ps-theme';
  var media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: light)') : null;
  function saved() {
    try { var v = localStorage.getItem(KEY); return v === 'dark' || v === 'light' ? v : 'device'; } catch (e) { return 'device'; }
  }
  function apply() {
    var choice = saved();
    var mode = choice === 'device' ? (media && media.matches ? 'light' : 'dark') : choice;
    document.documentElement.setAttribute('data-theme', mode);
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', mode === 'light' ? '#f3f5f8' : '#0a0d12');
  }
  window.getTheme = saved;
  window.setTheme = function (choice) {
    try { if (choice === 'device') localStorage.removeItem(KEY); else localStorage.setItem(KEY, choice); } catch (e) {}
    apply();
  };
  if (media && media.addEventListener) media.addEventListener('change', apply);
  // another tab on this device changed it
  window.addEventListener('storage', function (e) { if (e.key === KEY) apply(); });
  apply();
})();
