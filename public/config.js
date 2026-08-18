// Deployment config. Plain JS (not JSX) so it loads before anything else and is
// trivial to swap per environment.
//
// The publishable key is PUBLIC by design — it ships inside this bundle and anyone
// can read it. It grants nothing on its own: every table is RLS-protected and every
// api_* function is granted to `authenticated` only, so a signed-in session is
// required to read anything. SunSynk credentials live in Edge Function secrets and
// never reach the browser.
// Shown in Settings -> About. Bumped on every deploy; semver, so patch for fixes,
// minor for features, major for a rewrite. Lives here rather than in the JSX so it sits
// with the other deploy-time config and loads before anything renders.
window.APP_VERSION = 'v1.1.0';

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
