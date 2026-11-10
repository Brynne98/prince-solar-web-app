// Uncaught Edge Function errors go to PostHog as $exception (SOLAR-204), like the
// browser's crash reports (SOLAR-85, public/config.js). Same project, same public key,
// EU cloud. Tagged app = prince-solar-hub plus the function name.
//
// Only the error's type, message and stack are sent, with the signed-in user's Supabase
// id when the request has one (SOLAR-423): no request body, no email. Email addresses
// in a message are masked. A failed send is ignored: the error still goes to the
// Supabase log as before.

const POSTHOG_KEY = "phc_ABkqiYsajciVYVKYX4GZMApcDP7QfD7CKQtgE7XPgjxN";
const POSTHOG_URL = "https://eu.i.posthog.com/i/v0/e/";
// The release on every error and event: the web app version these functions were last
// deployed with. npm test fails when it is not public/config.js's APP_VERSION.
export const APP_VERSION = "v0.49.7";

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

// The user id (`sub`) in a request's sign-in token. Not checked here: it only labels the
// report. The service and publishable keys carry no `sub`, so a cron run has no user.
export function userOf(req: Request): string | null {
  try {
    const jwt = req.headers.get("Authorization")?.replace(/^Bearer /, "").split(".")[1];
    const sub = jwt && JSON.parse(atob(jwt.replace(/-/g, "+").replace(/_/g, "/"))).sub;
    return typeof sub === "string" ? sub : null;
  } catch { return null; }
}

export async function reportError(fn: string, e: unknown, userId: string | null = null): Promise<void> {
  const err = e instanceof Error ? e : new Error(String(e));
  try {
    await fetch(POSTHOG_URL, {
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
          $exception_list: [{
            type: err.name,
            value: scrub(err.message),
            mechanism: { handled: false, synthetic: !(e instanceof Error) },
            stacktrace: { type: "raw", frames: frames(scrub(err.stack ?? "")) },
          }],
        },
      }),
    });
  } catch { /* PostHog down: the Supabase log still has it */ }
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
// so the response is the same 500 as before.
export function serve(fn: string, handler: (req: Request) => Response | Promise<Response>) {
  return Deno.serve(async (req) => {
    try {
      return await handler(req);
    } catch (e) {
      await reportError(fn, e, userOf(req));
      throw e;
    }
  });
}
