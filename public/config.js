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
window.APP_VERSION = 'v0.34.5';
// Shown in Settings → About and on error screens.
window.SUPPORT_EMAIL = 'hello@princesolarhub.co.za';
// Google sign-in client (Google Cloud project prince-solar, "Supabase web"). Public by design.
window.GOOGLE_CLIENT_ID = '357189209576-890oqvan5eeuc2vash5ralv04k0m0pa2.apps.googleusercontent.com';
// Pop-up alerts (SOLAR-244): the VAPID public key. Public by design; its private half is
// the VAPID_KEYS secret on the notify function.
window.VAPID_PUBLIC = 'BJV8XqKj_ZTALuCxzfsKRYSvHZFnauOhVdKzs1njlexSoV8eabU5lgvt6VyL6l_Quoa9QbO3IEnKaKEvQP0aocg';

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

// Usage events and crash reports go to PostHog, EU cloud (SOLAR-85). The project key is
// public by design, like the publishable key above. Nothing is kept in the browser
// (memory persistence: no cookie, so no banner); a signed-in user is known by their
// Supabase user id only. No screen recording, no click capture: only the named events
// sent through window.track, and errors. Empty key: nothing is sent.
window.POSTHOG_KEY = 'phc_ABkqiYsajciVYVKYX4GZMApcDP7QfD7CKQtgE7XPgjxN';
(function () {
  var ph = window.posthog;
  var on = !!(window.POSTHOG_KEY && ph && ph.init);
  // Memory persistence mints a new anonymous id each load; start a signed-in user on
  // their user id (from the saved Supabase session) so identify doesn't merge a new id
  // onto them every visit.
  var uid = null;
  try { uid = JSON.parse(localStorage.getItem('synsynk.auth')).user.id; } catch (e) {}
  if (on) {
    ph.init(window.POSTHOG_KEY, {
      bootstrap: uid ? { distinctID: uid, isIdentifiedID: true } : {},
      api_host: 'https://eu.i.posthog.com',
      persistence: 'memory',
      autocapture: false, rageclick: false, capture_pageview: false, capture_pageleave: false,
      capture_heatmaps: false, capture_dead_clicks: false, capture_performance: false,
      disable_session_recording: true, disable_surveys: true, disable_web_experiments: true,
      advanced_disable_flags: true, disable_external_dependency_loading: true,
    });
    // The project is shared with the phone apps: filter on app = prince-solar-hub.
    ph.register({ app: 'prince-solar-hub', app_version: window.APP_VERSION });
  }
  window.track = function (name, props) {
    try { if (on) ph.capture(name, Object.assign({ plant_id: window.CURRENT_PLANT ?? null }, props)); } catch (e) {}
  };
  window.identifyUser = function (id) {
    try { if (on) { if (!id) ph.reset(); else if (id !== ph.get_distinct_id()) ph.identify(id); } } catch (e) {}
  };
  // A crash in someone's browser is otherwise invisible. Each message once per page
  // load, at most 20, so a render loop can't flood the project.
  var seen = {}, count = 0;
  var report = function (err) {
    try {
      var key = String((err && err.message) || err).slice(0, 200);
      if (!on || seen[key] || count >= 20) return;
      seen[key] = true; count++;
      ph.captureException(err instanceof Error ? err : new Error(key), { page: location.pathname + location.search });
    } catch (e) {}
  };
  window.addEventListener('error', function (e) { report(e.error || e.message); });
  window.addEventListener('unhandledrejection', function (e) { report(e.reason); });
  window.reportClientError = report;
})();
