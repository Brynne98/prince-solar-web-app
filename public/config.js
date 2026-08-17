// Deployment config. Plain JS (not JSX) so it loads before anything else and is
// trivial to swap per environment.
//
// The publishable key is PUBLIC by design — it ships inside this bundle and anyone
// can read it. It grants nothing on its own: every table is RLS-protected and every
// api_* function is granted to `authenticated` only, so a signed-in session is
// required to read anything. SunSynk credentials live in Edge Function secrets and
// never reach the browser.
// Shown in the footer. Semver: patch for fixes, minor for features, major for a
// rewrite. It lives here rather than in the JSX so it sits next to the other
// deploy-time config and loads before anything renders.
window.APP_VERSION = 'v1.0.0';

window.SUNSYNK_CONFIG = (function () {
  var local = {
    url: 'http://127.0.0.1:55321',
    // shared local-dev default printed by `supabase start` — not a secret
    key: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
  };
  var prod = {
    url: 'https://pmakzojwhouamawgszrc.supabase.co',
    key: 'sb_publishable_PTYy9-EiqSFUVaFMLlCMnQ_DejfmixB',
  };
  var host = location.hostname;
  var isLocal = host === 'localhost' || host === '127.0.0.1' || host === '';
  return isLocal ? local : prod;
})();
