// `notify-push` (SOLAR-645 step 2, cron every minute from 0257): the pop-ups, on their own
// clock so a slow email run never starves them. No Resend.
// The outbox (step 3, 0261): one send per device, tried again on 429, 5xx or no answer
// (notify's outboxPushPass, ../notify/index.ts).
//
// Off when VAPID_KEYS is unset, NOTIFY_LIVE isn't "1", or ?dry=1: then it sends and marks nothing.
import { denyUnlessServer } from "../_shared/sunsynk.ts";
import { noteError, reportError, serve } from "../_shared/errors.ts";
import { json, LIVE, outboxPushPass, VAPID_KEYS } from "../notify/index.ts";

// The cron call times out at 55 s.
const DEADLINE_MS = 50_000;
/** The outbox pass. A failure is noted, not thrown. */
export const run = (outbox: (deadline: number) => Promise<unknown>, started: number) =>
  outbox(started + DEADLINE_MS).then((o) => ({ outbox: o }), (e) => {
    noteError("push_outbox_failed", e, { hourly: true });
    return { outbox: { error: String(e instanceof Error ? e.message : e) } };
  });

if (import.meta.main) serve("notify-push", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const on = !!VAPID_KEYS && LIVE && new URL(req.url).searchParams.get("dry") !== "1";
  try {
    return json({ live: on, ...(on ? await run((d) => outboxPushPass(d), Date.now()) : {}) });
  } catch (e) {
    await reportError("notify-push", e);
    console.error("notify-push failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
