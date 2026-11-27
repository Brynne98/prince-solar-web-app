// `plant-jobs` — the reader's side jobs (SOLAR-681 R18), in a function of their own so a long
// plant-sync minute never holds up a poll group: { task: "sync" } each login's inverter and plant
// lists on its own minutes (today's temperatures are History's: EF/history). Called each minute
// by pg_cron (private.schedule_jobs); the server key only.
import { reportError, serve } from "../_shared/errors.ts";
import { denyUnlessServer } from "../_shared/server.ts";
import { runSync } from "../_shared/sidejobs.ts";

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
const nowMinuteEpoch = () => Math.floor(Date.now() / 60000) * 60;

serve("plant-jobs", async (req) => {
  const denied = denyUnlessServer(req);
  if (denied) return denied;
  try {
    const body = await req.json().catch(() => ({})) as Record<string, unknown>;
    if (body.task === "sync") return json({ ok: true, task: "sync", ...(await runSync(nowMinuteEpoch())) });
    return json({ error: "task must be sync" }, 400);
  } catch (e) {
    await reportError("plant-jobs", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
