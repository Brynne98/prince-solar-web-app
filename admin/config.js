// Same Supabase project as public/config.js. The publishable key is public by design;
// admin data comes only from admin_overview(), which refuses anyone not in private.admins.
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
