// `health` (SOLAR-469): an outside uptime service calls this every 5 minutes and emails
// admin@ when it doesn't answer 200. 503 when the database can't be reached, or when
// job-check (every 5 min from pg_cron, SOLAR-428) last ran over 15 minutes ago: then
// pg_cron, pg_net or the functions have stopped and nothing inside would say so.
// No sign-in (config.toml verify_jwt = false); the answer holds no data beyond minutes.
import { createClient } from "jsr:@supabase/supabase-js@2.118.0";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
                        { auth: { persistSession: false } });
const STALE_MIN = 15;

const answer = (ok: boolean, body: Record<string, unknown>) =>
  new Response(JSON.stringify({ ok, ...body }), {
    status: ok ? 200 : 503,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

Deno.serve(async () => {
  const r = await Promise.race([
    db.rpc("uptime_health"),
    new Promise<{ data: null; error: Error }>((ok) => setTimeout(() => ok({ data: null, error: new Error("timeout") }), 8000)),
  ]);
  if (r.error || !r.data) return answer(false, { reason: "database" });
  const min = (r.data as { job_check_minutes: number | null }).job_check_minutes;
  if (min == null || min > STALE_MIN) return answer(false, { reason: "job-check silent", minutes: min });
  return answer(true, { minutes: min });
});
