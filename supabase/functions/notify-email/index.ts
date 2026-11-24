// `notify-email` (SOLAR-645 step 2, cron every minute from 0257): the one Resend sender.
// Each run: the sweeps (email_sweep; the billing sweep runs inside the billing pass), then
// alert emails, then the billing outbox, then the rest (welcome, reports, history, ...).
// All three share one Resend pace, and a 429 holds all of them until its Retry-After.
// Pop-ups are notify-push. The building and sending is notify's (../notify/index.ts).
//
// Nothing is sent unless NOTIFY_LIVE is "1" and RESEND_API_KEY is set. Otherwise, and with
// ?dry=1, nothing is written and the answer lists what each lane would send next.
import { denyUnlessServer } from "../_shared/sunsynk.ts";
import { noteError, reportError, serve } from "../_shared/errors.ts";
import { emailPass, json, LIVE, outboxPass, RESEND_KEY, sweep } from "../notify/index.ts";

// The cron call times out at 55 s. Claims stop at these marks from the start; whatever
// is claimed and not sent by DEADLINE_MS goes back untouched.
export const URGENT_MS = 35_000, BILLING_MS = 42_000, BULK_MS = 45_000, DEADLINE_MS = 50_000;

export type Passes = {
  sweep: () => Promise<unknown>;
  email: (lane: "urgent" | "bulk", until: number, deadline: number) => Promise<unknown>;
  billing: (deadline: number) => Promise<unknown>;
};

/** One run, in order: sweep, alert emails, billing, the rest. A dry run skips what writes. */
export async function drain(p: Passes, started: number, dry: boolean) {
  const swept = dry ? null : await p.sweep();
  const urgent = await p.email("urgent", started + URGENT_MS, started + DEADLINE_MS);
  const billing = dry ? null : await p.billing(started + BILLING_MS).catch((e) => {
    noteError("outbox_pass_failed", e, { hourly: true });
    return { error: String(e?.message ?? e) };
  });
  const bulk = await p.email("bulk", started + BULK_MS, started + DEADLINE_MS);
  return { live: !dry, swept, urgent, billing, bulk };
}

if (import.meta.main) serve("notify-email", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const dry = !LIVE || !RESEND_KEY || new URL(req.url).searchParams.get("dry") === "1";
  try {
    return json(await drain({
      sweep,
      email: (lane, until, deadline) => emailPass(lane, until, deadline, dry),
      billing: outboxPass,
    }, Date.now(), dry));
  } catch (e) {
    await reportError("notify-email", e);
    console.error("notify-email failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
