// `notify-push` (SOLAR-645 step 2, cron every minute from 0257): the pop-ups, on their own
// clock so a slow email run never starves them. No Resend.
//   1. push_claim: rows queued before pop-ups moved to the outbox, each browser tried once,
//      and the "not an alert" marks (notify's pushPass, ../notify/index.ts).
//   2. the outbox (step 3, 0261): one send per device, tried again on 429, 5xx or no answer
//      (outboxPushPass). Before 0261 is applied its RPC is missing; that is noted, not fatal.
//
// Off when VAPID_KEYS is unset, NOTIFY_LIVE isn't "1", or ?dry=1: then it sends and marks nothing.
import { denyUnlessServer } from "../_shared/sunsynk.ts";
import { noteError, reportError, serve } from "../_shared/errors.ts";
import { json, LIVE, outboxPushPass, pushPass, VAPID_KEYS } from "../notify/index.ts";

// The cron call times out at 55 s.
const DEADLINE_MS = 50_000;
// The old path is a few rows at most since 0261; it gets the first 10 s.
const OLD_MS = 10_000;

export type Passes = { old: (deadline: number) => Promise<unknown>; outbox: (deadline: number) => Promise<unknown> };

/** Old path first, then the outbox; a failed outbox pass leaves the old one's result. */
export async function run(p: Passes, started: number) {
  const pushed = await p.old(started + OLD_MS);
  const outbox = await p.outbox(started + DEADLINE_MS).catch((e) => {
    noteError("push_outbox_failed", e, { hourly: true });
    return { error: String(e instanceof Error ? e.message : e) };
  });
  return { pushed, outbox };
}

if (import.meta.main) serve("notify-push", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const on = !!VAPID_KEYS && LIVE && new URL(req.url).searchParams.get("dry") !== "1";
  try {
    return json({ live: on, ...(on ? await run({ old: pushPass, outbox: (d) => outboxPushPass(d) }, Date.now()) : {}) });
  } catch (e) {
    await reportError("notify-push", e);
    console.error("notify-push failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
