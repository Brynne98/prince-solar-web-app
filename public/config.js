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
window.APP_VERSION = 'v0.55.9';
// Shown in Settings → About and on error screens.
window.SUPPORT_EMAIL = 'hello@princesolarhub.co.za';
// Google sign-in client (Google Cloud project prince-solar, "Supabase web"). Public by design.
window.GOOGLE_CLIENT_ID = '357189209576-890oqvan5eeuc2vash5ralv04k0m0pa2.apps.googleusercontent.com';
// Pop-up alerts (SOLAR-244): the VAPID public key. Public by design; its private half is
// the VAPID_KEYS secret on the notify function.
window.VAPID_PUBLIC = 'BJV8XqKj_ZTALuCxzfsKRYSvHZFnauOhVdKzs1njlexSoV8eabU5lgvt6VyL6l_Quoa9QbO3IEnKaKEvQP0aocg';

// Bot check on sign-in, sign-up and reset (SOLAR-533): the Cloudflare Turnstile site key.
// Public by design; its secret half is in Supabase (Authentication > Bot and Abuse Protection).
// Empty: no check is shown and no token is sent. Local runs use Cloudflare's always-pass test key.
window.TURNSTILE_SITE_KEY = /^(localhost|127\.0\.0\.1|)$/.test(location.hostname) ? '1x00000000000000000000AA'
  : location.hostname === 'app.princesolarhub.co.za' ? '0x4AAAAAAF-QtcA91pYqz9Sp' : '';

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
window.POSTHOG_KEY = 'phc_nSjRSg8gz7TMY2vis42JcKchyia6FpwYJqFrV5CKSu3v';
(function () {
  var ph = window.posthog;
  // Local runs (localhost, 127.0.0.1) send nothing: their test users are not customers (SOLAR-268).
  var local = /^(localhost|127\.0\.0\.1|)$/.test(location.hostname);
  var on = !!(window.POSTHOG_KEY && ph && ph.init) && !local;
  // Memory persistence mints a new anonymous id each load; start a signed-in user on
  // their user id (from the saved Supabase session) so identify doesn't merge a new id
  // onto them every visit.
  var uid = null;
  // An address keeps its host and path only: a query or #hash can hold a payment reference,
  // a plant id or a sign-in token (SOLAR-533).
  var bare = function (u) { return typeof u === 'string' && /^https?:\/\//i.test(u) ? u.split(/[?#]/)[0] : u; };
  var scrub = function (s) {
    return String(s || '').replace(/[^\s"'<>@]+@[^\s"'<>@]+\.[a-z]{2,}/gi, '[email]')
      .replace(/(https?:\/\/[^\s"'<>?#]+)[?#][^\s"'<>]*/gi, '$1');
  };
  // Database and server error text: quoted values, bracketed values and long numbers out, 80 characters.
  var mask = function (s) { return scrub(s).replace(/"[^"]*"|'[^']*'|\([^)]*\)/g, '…').replace(/\d{4,}/g, '#').slice(0, 80); };
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
      // Before anything leaves the browser: every address loses its query and #hash (SOLAR-533),
      // and an email in an error message is masked (SOLAR-423).
      before_send: function (ev) {
        try {
          var p = ev.properties || {};
          [p, p.$set, p.$set_once, ev.$set, ev.$set_once].forEach(function (o) { for (var k in o) o[k] = bare(o[k]); });
          if (ev.event === '$exception') p.$exception_list.forEach(function (x) { x.value = scrub(x.value); });
        } catch (e) {}
        return ev;
      },
    });
    // The project is shared with the phone apps: filter on app = prince-solar-hub, split by
    // platform (web, ios, android, edge). app_version is the release on events and errors
    // alike. ANALYTICS.md has the full list (SOLAR-423).
    ph.register({ app: 'prince-solar-hub', platform: 'web', app_version: window.APP_VERSION });
  }
  window.track = function (name, props) {
    try { if (on) ph.capture(name, Object.assign({ plant_id: window.CURRENT_PLANT ?? null }, props)); } catch (e) {}
  };
  window.identifyUser = function (id) {
    try { if (on) { if (!id) ph.reset(); else if (id !== ph.get_distinct_id()) ph.identify(id); } } catch (e) {}
  };
  // A crash in someone's browser is otherwise invisible. Each message once per page
  // load, at most 20, so a render loop can't flood the project. Returns the PostHog event
  // id, and keeps the last one in window.lastErrorId for "Report this" (SOLAR-428).
  var seen = {}, count = 0;
  var report = function (err, props) {
    try {
      var key = String((err && err.message) || err).slice(0, 200);
      if (!on) return null;
      if (seen[key] || count >= 20) {
        var old = typeof seen[key] === 'string' ? seen[key] : null;
        if (old) window.lastErrorId = { id: old, at: Date.now() };
        return old;
      }
      count++;
      // No code location (a thrown string, "Script error." from another site's script, an
      // Error with no stack): PostHog would group them all under one old issue, so a new one
      // sends no "new error" email. Group these by their message instead (SOLAR-472).
      var stackless = !(err instanceof Error) || !/:\d+:\d+/.test(err.stack || '');
      var r = ph.captureException(err instanceof Error ? err : new Error(key), Object.assign({ page: location.pathname },
        stackless ? { $exception_fingerprint: 'message:' + scrub(key).slice(0, 120) } : {}, props));
      seen[key] = (r && r.uuid) || true;
      if (r && r.uuid) window.lastErrorId = { id: r.uuid, at: Date.now() };
      return (r && r.uuid) || null;
    } catch (e) { return null; }
  };
  window.addEventListener('error', function (e) { report(e.error || e.message); });
  window.addEventListener('unhandledrejection', function (e) { report(e.reason); });
  window.reportClientError = report;
  // A Supabase call the server or database failed (SOLAR-472): a 5xx, or a Postgres error
  // that isn't a deliberate refusal (22: bad value such as 22023, 23: constraint, 28 and
  // 42501: not allowed, P0: raised by our own code). Not sent: offline (status 0) and other
  // 4xx. 42501 is sent when Postgres itself says "permission denied ..." to a signed-in user
  // (403): a table or function right is missing, which is our mistake, not a refusal. Signed
  // out (401, a session that ended) it is expected and stays unsent (SOLAR-536).
  // Each RPC and code is its own issue; at most 5 per page load.
  var serverErrors = 0;
  window.reportServerError = function (name, error, status) {
    var code = String((error && error.code) || '');
    var dbFault = /^[0-9A-Z]{5}$/.test(code) && !/^(22|23|28|P0)|^42501$/.test(code)
      || code === '42501' && status !== 401 && /^permission denied/.test((error && error.message) || '');
    if (!(status >= 500 || dbFault || code === 'PGRST202') || serverErrors >= 5) return null;
    serverErrors++;
    return report(new Error(name + ': ' + (code || status) + ' ' + mask(error && error.message)), {
      $exception_fingerprint: 'rpc:' + name + ':' + (code || status), rpc: name, code: code || null, status: status || null,
    });
  };
})();
