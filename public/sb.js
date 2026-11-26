// The one Supabase client, for every module (it was window.sb). Reads its address and key
// from config.js, which loads first as a plain script.
import { createClient } from '@supabase/supabase-js';

/** @type {import('@supabase/supabase-js').SupabaseClient<import('../supabase/functions/_shared/database.types.ts').Database>} */
export const sb = createClient(
  window.SUNSYNK_CONFIG.url,
  window.SUNSYNK_CONFIG.key,
  { auth: { persistSession: true, autoRefreshToken: true, storageKey: 'synsynk.auth' },
    global: { fetch: fetchWithRefreshCutoff } }
);

// supabase-js renews an expired sign-in before any other request goes out, holding a
// lock until the renewal answers, and sends it with no time limit. A tablet waking up
// can send it on a connection that died while asleep, so it never answers and every
// read waits behind it ("Couldn't check your SunSynk logins — timed out", SOLAR-21).
// Cut the renewal off after 5 s; supabase-js counts that as a network failure and
// sends it again, on a fresh connection. Only the renewal: sign-up and other calls
// can rightly take longer.
function fetchWithRefreshCutoff(url, opts) {
  if (!String(url).includes('grant_type=refresh_token') || (opts && opts.signal)) return fetch(url, opts);
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 5000);
  return fetch(url, { ...opts, signal: ctl.signal }).finally(() => clearTimeout(timer));
}
