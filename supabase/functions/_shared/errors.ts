// Uncaught Edge Function errors go to PostHog as $exception (SOLAR-204), like the
// browser's crash reports (SOLAR-85, public/config.js). Same project, same public key,
// EU cloud. Tagged app = prince-solar-hub plus the function name.
//
// Only the error's type, message and stack are sent, with the signed-in user's Supabase
// id when the request has one (SOLAR-423): no request body, no email. Email addresses
// in a message are masked. A failed send is ignored: the error still goes to the
// Supabase log as before.

const POSTHOG_KEY = "phc_nSjRSg8gz7TMY2vis42JcKchyia6FpwYJqFrV5CKSu3v";
const POSTHOG_URL = "https://eu.i.posthog.com/i/v0/e/";
// The release on every error and event: the web app version these functions were last
// deployed with. npm test fails when it is not public/config.js's APP_VERSION.
export const APP_VERSION = "v0.55.8";

const scrub = (s: string) => s.replace(/[^\s"'<>@]+@[^\s"'<>@]+\.[a-z]{2,}/gi, "[email]");

// "    at fn (file:///…/poll/index.ts:12:3)" → a PostHog raw frame.
function frames(stack: string) {
  return stack.split("\n").slice(1).map((line) => {
    const m = line.match(/at (?:(.+?) \()?(.+?):(\d+):(\d+)\)?$/);
    return m && {
      function: m[1] ?? "?", filename: m[2], lineno: Number(m[3]), colno: Number(m[4]),
      platform: "custom", lang: "javascript", in_app: !m[2].startsWith("ext:"),
    };
  }).filter(Boolean).reverse();
}

// The signed-in user behind a request, asked of Supabase Auth so a made-up token can't
// file an error under someone else. Some functions skip the gateway's sign-in check
// (config.toml verify_jwt = false). Only runs on an error. A cron run, the service key or
// a bad token gives null.
export async function userOf(req: Request): Promise<string | null> {
  const auth = req.headers.get("Authorization");
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!auth?.startsWith("Bearer ") || !url || !key) return null;
  try {
    const r = await fetch(`${url}/auth/v1/user`, { headers: { apikey: key, Authorization: auth }, signal: AbortSignal.timeout(3000) });
    return r.ok ? ((await r.json()).id ?? null) : null;
  } catch { return null; }
}

function send(fn: string, e: unknown, userId: string | null, handled: boolean, props: Record<string, unknown> = {}, type?: string) {
  const err = e instanceof Error ? e : new Error(String(e));
  return fetch(POSTHOG_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    signal: AbortSignal.timeout(3000),
    body: JSON.stringify({
      api_key: POSTHOG_KEY,
      event: "$exception",
      distinct_id: userId ?? `edge:${fn}`,
      properties: {
        app: "prince-solar-hub",
        platform: "edge",
        app_version: APP_VERSION,
        function: fn,
        $process_person_profile: false,
        ...props,
        $exception_list: [{
          type: type ?? err.name,
          value: scrub(err.message),
          mechanism: { handled, synthetic: !(e instanceof Error) },
          stacktrace: { type: "raw", frames: frames(scrub(err.stack ?? "")) },
        }],
      },
    }),
  }).then((r) => r.ok, () => false); // PostHog down: the Supabase log still has it
}

export async function reportError(fn: string, e: unknown, userId: string | null = null): Promise<void> {
  await send(fn, e, userId, false);
}

// Caught failures (SOLAR-336): a refund Paystack refused, a SunSynk 502, a Resend
// refusal. Noted as they happen, sent when the request ends (serve), one report per kind
// with a count, so a run where 40 plants hit the same SunSynk 504 is one report. Each
// kind is its own PostHog issue (the fingerprint), named by the kind, whatever ids its
// message holds.
// hourly: a kind that can repeat every minute (SunSynk, Resend) sends at most once an
// hour; the gap is kept in app_config, so it holds across runs. Only ids go with it:
// the user's Supabase id, plant ids, a payment reference.
// day: a date the failure is about (SOLAR-525); every "plant:day" pair is sent as `days`.
type Note = { e: unknown; count: number; user: string | null; plants: Set<number>; days: string[]; ref?: string; hourly: boolean };
const notes = new Map<string, Note>();
let served = "edge";

export function noteError(kind: string, e: unknown,
  at: { user?: string | null; plant?: number | string | null; day?: string; ref?: string; hourly?: boolean } = {}) {
  const n = notes.get(kind) ?? { e, count: 0, user: at.user ?? null, plants: new Set<number>(), days: [], ref: at.ref, hourly: !!at.hourly };
  n.count++;
  if (at.plant != null && Number.isSafeInteger(Number(at.plant))) n.plants.add(Number(at.plant));
  if (at.day) n.days.push(`${at.plant ?? "?"}:${at.day}`);
  notes.set(kind, n);
}

const HOUR_S = 3600;
async function sentWithinHour(keys: string[]): Promise<{ recent: Set<string>; mark: (ks: string[]) => Promise<void> }> {
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const none = { recent: new Set<string>(), mark: async () => {} };
  if (!url || !key || !keys.length) return none;
  const headers = { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" };
  const now = Date.now() / 1000;
  try {
    const r = await fetch(`${url}/rest/v1/app_config?select=key,value&key=in.(${keys.map((k) => `"${k}"`).join(",")})`,
      { headers, signal: AbortSignal.timeout(3000) });
    const rows: { key: string; value: number }[] = r.ok ? await r.json() : [];
    return {
      recent: new Set(rows.filter((x) => now - x.value < HOUR_S).map((x) => x.key)),
      mark: async (ks) => {
        if (!ks.length) return;
        await fetch(`${url}/rest/v1/app_config?on_conflict=key`, {
          method: "POST", headers: { ...headers, Prefer: "resolution=merge-duplicates,return=minimal" },
          signal: AbortSignal.timeout(3000),
          body: JSON.stringify(ks.map((k) => ({ key: k, value: now, note: "last error report of this kind (SOLAR-336)" }))),
        }).catch(() => {});
      },
    };
  } catch { return none; }
}

/** Sends what noteError gathered. serve() calls it when a request ends; work left
 *  running after the response calls it itself. */
export async function flushErrors(fn = served): Promise<void> {
  if (!notes.size) return;
  const batch = [...notes.entries()];
  notes.clear();
  const keyOf = (kind: string) => `error_sent:${fn}:${kind}`;
  const gate = await sentWithinHour(batch.filter(([, n]) => n.hourly).map(([k]) => keyOf(k)));
  const due = batch.filter(([k, n]) => !n.hourly || !gate.recent.has(keyOf(k)));
  const sent = await Promise.all(due.map(([kind, n]) => send(fn, n.e, n.user, true, {
    kind, count: n.count, $exception_fingerprint: `${fn}:${kind}`,
    ...(n.plants.size ? { plant_ids: [...n.plants].slice(0, 50) } : {}),
    ...(n.days.length ? { days: n.days.slice(0, 50) } : {}),
    ...(n.ref ? { reference: n.ref } : {}),
  }, kind)));
  // Only what PostHog took starts the hour; a failed send goes again next run.
  await gate.mark(due.filter(([, n], i) => n.hourly && sent[i]).map(([k]) => keyOf(k)));
}

// A product event for one user, by Supabase user id only (CLAUDE.md, Analytics). The
// same `once` and `at` give the same uuid and time, which PostHog keeps as one event,
// so a step that runs twice counts once. A failed send is ignored.
export async function track(event: string, userId: string, once: string, at: string, properties: Record<string, unknown> = {}) {
  const h = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${event}:${once}`)))]
    .slice(0, 16).map((b) => b.toString(16).padStart(2, "0")).join("");
  const uuid = `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
  try {
    await fetch(POSTHOG_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: AbortSignal.timeout(3000),
      body: JSON.stringify({ api_key: POSTHOG_KEY, event, uuid, timestamp: at, distinct_id: userId, properties: { app: "prince-solar-hub", platform: "edge", app_version: APP_VERSION, ...properties } }),
    });
  } catch { /* PostHog down: the event is lost, nothing else */ }
}

// Deno.serve for a function: anything the handler throws is reported, then rethrown,
// so the response is the same 500 as before. Failures noted on the way are sent last.
export function serve(fn: string, handler: (req: Request) => Response | Promise<Response>) {
  served = fn;
  return Deno.serve(async (req) => {
    try {
      return await handler(req);
    } catch (e) {
      await reportError(fn, e, await userOf(req));
      throw e;
    } finally {
      await flushErrors(fn);
    }
  });
}
