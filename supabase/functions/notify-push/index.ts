// `notify-push` (SOLAR-645 step 2, cron every minute from 0257): the pop-ups, on their own
// clock so a slow email run never starves them. No Resend. push_claim hands over the alerts
// due one; each browser is tried once (notify's pushPass, ../notify/index.ts).
//
// Off when VAPID_KEYS is unset, NOTIFY_LIVE isn't "1", or ?dry=1: then it sends and marks nothing.
import { denyUnlessServer } from "../_shared/sunsynk.ts";
import { reportError, serve } from "../_shared/errors.ts";
import { json, LIVE, pushPass, VAPID_KEYS } from "../notify/index.ts";

// The cron call times out at 55 s.
const DEADLINE_MS = 50_000;

if (import.meta.main) serve("notify-push", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  const on = !!VAPID_KEYS && LIVE && new URL(req.url).searchParams.get("dry") !== "1";
  try {
    return json({ live: on, pushed: on ? await pushPass(Date.now() + DEADLINE_MS) : null });
  } catch (e) {
    await reportError("notify-push", e);
    console.error("notify-push failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
