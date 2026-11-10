// `job-check` (SOLAR-428): every 5 minutes from pg_cron (0180). Reads job_check_inputs(),
// judges each check, saves the ones whose state flipped and sends PostHog
// job_check_failed / job_check_recovered for them, distinct id edge:<job>. Each run also
// sends job_check_ran, so a PostHog alert hears when the check itself stops.
import { db } from "../_shared/sunsynk.ts";
import { serve, track } from "../_shared/errors.ts";

type Job = { job: string; schedule: string; active: boolean; last_start: string | null; last_status: string | null; last_end: string | null; message: string };
type Inputs = {
  now: string;
  shards: { shard: number; last_at: string | null }[];
  jobs: Job[];
  sunsynk: { calls: number; failed: number; since: string | null };
  email: { waiting: number; oldest_due: string | null };
  checks: Record<string, { failing: boolean; since: string }>;
};
type Verdict = { name: string; job: string; failing: boolean | null; detail: Record<string, unknown> };

const SHARD_SILENT_MS = 5 * 60_000;
const CRON_GRACE_MS = 3 * 60_000;   // a run may start this late before it counts as missed

// One cron field ("*", "*/5", "4-5", "10,40", "1-30/2") as the set of values it allows,
// or null when pg_cron syntax we don't read ("$", "30 seconds").
function field(spec: string, lo: number, hi: number): Set<number> | null {
  const out = new Set<number>();
  for (const part of spec.split(",")) {
    const m = part.match(/^(\*|(\d+)(?:-(\d+))?)(?:\/(\d+))?$/);
    if (!m) return null;
    const a = m[1] === "*" ? lo : Number(m[2]);
    const b = m[1] === "*" ? hi : m[3] != null ? Number(m[3]) : m[4] ? hi : a;
    const step = Number(m[4] ?? 1);
    if (a < lo || b > hi || step < 1) return null;
    for (let v = a; v <= b; v += step) out.add(v === 7 && hi === 7 ? 0 : v);
  }
  return out;
}

// The last minute at or before `t` the schedule fires (pg_cron runs in GMT), looking back 8
// days. Day of month and day of week both restricted: either may match, as in cron.
export function lastFire(schedule: string, t: number): number | null {
  const p = schedule.trim().split(/\s+/);
  if (p.length !== 5) return null;
  const [mi, ho, dm, mo, dw] = [field(p[0], 0, 59), field(p[1], 0, 23), field(p[2], 1, 31), field(p[3], 1, 12), field(p[4], 0, 7)];
  if (!mi || !ho || !dm || !mo || !dw) return null;
  const anyDm = p[2] === "*", anyDw = p[4] === "*";
  for (let x = Math.floor(t / 60_000) * 60_000, end = t - 8 * 86_400_000; x > end; x -= 60_000) {
    const d = new Date(x);
    if (!mi.has(d.getUTCMinutes()) || !ho.has(d.getUTCHours()) || !mo.has(d.getUTCMonth() + 1)) continue;
    const dayOk = anyDm || anyDw ? dm.has(d.getUTCDate()) && dw.has(d.getUTCDay())
                                 : dm.has(d.getUTCDate()) || dw.has(d.getUTCDay());
    if (dayOk) return x;
  }
  return null;
}

export function judge(i: Inputs): Verdict[] {
  const now = Date.parse(i.now);
  const out: Verdict[] = [];
  for (const s of i.shards) {
    // A shard with no run yet is new (more accounts this minute): judged once it has one.
    if (!s.last_at) continue;
    const ago = now - Date.parse(s.last_at);
    out.push({ name: `poll:s${s.shard}`, job: "poll", failing: ago > SHARD_SILENT_MS,
               detail: { shard: s.shard, last_run: s.last_at, minutes_silent: Math.floor(ago / 60_000) } });
  }
  for (const j of i.jobs) {
    if (!j.active) continue;
    const due = lastFire(j.schedule, now - CRON_GRACE_MS);
    const missed = due != null && j.last_start != null && Date.parse(j.last_start) < due - 30_000;
    const failed = j.last_status === "failed";
    out.push({ name: `cron:${j.job}`, job: j.job, failing: failed || missed,
               detail: { reason: failed ? "failed" : missed ? "missed" : null, schedule: j.schedule,
                         last_start: j.last_start, ...(failed ? { message: j.message } : {}),
                         ...(missed ? { due: new Date(due!).toISOString() } : {}) } });
  }
  const { calls, failed } = i.sunsynk;
  const share = calls > 0 ? failed / calls : 0;
  // Under 20 calls the share says little: the state stays as it was.
  out.push({ name: "sunsynk", job: "sunsynk", failing: calls < 20 ? null : share >= 0.2 ? true : share < 0.1 ? false : null,
             detail: { calls, failed, failed_share: Math.round(share * 1000) / 1000, since: i.sunsynk.since } });
  out.push({ name: "email-queue", job: "notify", failing: i.email.waiting > 0,
             detail: { waiting: i.email.waiting, oldest_due: i.email.oldest_due } });
  // A failing check whose shard or job is gone (fewer shards, job unscheduled) clears.
  for (const [name, c] of Object.entries(i.checks)) {
    if (c.failing && !out.some((v) => v.name === name)) {
      out.push({ name, job: name.startsWith("poll:") ? "poll" : name.replace(/^cron:/, ""), failing: false, detail: { gone: true } });
    }
  }
  return out;
}

const rpc = async (fn: string, args: Record<string, unknown> = {}) => {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
};

// The gateway has checked the token's signature; only the service role may run this.
function isService(req: Request): boolean {
  try {
    const jwt = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "") ?? "";
    return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).role === "service_role";
  } catch { return false; }
}

if (import.meta.main) serve("job-check", async (req) => {
  if (!isService(req)) return new Response("forbidden", { status: 403 });
  const i = await rpc("job_check_inputs") as Inputs;
  const verdicts = judge(i);
  const changes = verdicts.filter((v) => v.failing != null && v.failing !== (i.checks[v.name]?.failing ?? false));
  if (changes.length) await rpc("job_check_save", { p_changes: changes.map(({ name, failing, detail }) => ({ name, failing, detail })) });
  const at = i.now;
  await Promise.all([
    ...changes.map((v) => {
      const since = i.checks[v.name]?.since;
      return v.failing
        ? track("job_check_failed", `edge:${v.job}`, `${v.name}:${at}`, at, { check: v.name, job: v.job, ...v.detail, $process_person_profile: false })
        : track("job_check_recovered", `edge:${v.job}`, `${v.name}:${at}`, at, {
            check: v.name, job: v.job, ...v.detail, $process_person_profile: false,
            minutes_down: since ? Math.round((Date.parse(at) - Date.parse(since)) / 60_000) : null });
    }),
    track("job_check_ran", "edge:job-check", `ran:${at.slice(0, 16)}`, at, {
      failing: verdicts.filter((v) => v.failing ?? i.checks[v.name]?.failing).map((v) => v.name),
      $process_person_profile: false }),
  ]);
  return new Response(JSON.stringify({ changes: changes.map((v) => ({ name: v.name, failing: v.failing })) }),
                      { headers: { "Content-Type": "application/json" } });
});
