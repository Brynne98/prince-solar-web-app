// Uncaught Edge Function errors go to PostHog as $exception (SOLAR-204), like the
// browser's crash reports (SOLAR-85, public/config.js). Same project, same public key,
// EU cloud. Tagged app = prince-solar-hub plus the function name.
//
// Only the error's type, message and stack are sent: no request body, no user. Email
// addresses in a message are masked. A failed send is ignored: the error still goes
// to the Supabase log as before.

const POSTHOG_KEY = "phc_ABkqiYsajciVYVKYX4GZMApcDP7QfD7CKQtgE7XPgjxN";
const POSTHOG_URL = "https://eu.i.posthog.com/i/v0/e/";

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

export async function reportError(fn: string, e: unknown): Promise<void> {
  const err = e instanceof Error ? e : new Error(String(e));
  try {
    await fetch(POSTHOG_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: AbortSignal.timeout(3000),
      body: JSON.stringify({
        api_key: POSTHOG_KEY,
        event: "$exception",
        distinct_id: `edge:${fn}`,
        properties: {
          app: "prince-solar-hub",
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

// Deno.serve for a function: anything the handler throws is reported, then rethrown,
// so the response is the same 500 as before.
export function serve(fn: string, handler: (req: Request) => Response | Promise<Response>) {
  return Deno.serve(async (req) => {
    try {
      return await handler(req);
    } catch (e) {
      await reportError(fn, e);
      throw e;
    }
  });
}
