// Today's inverter temperatures (SOLAR-398), moved here from the reader's side jobs (SOLAR-686
// H12): each inverter's day so far once in ten minutes, on its own minute, through the login that
// reads the plant now; and today's grid Hz once an hour (it only ran in recover before).
import { rpc } from "../_shared/db.ts";
import { type Account, brandOf, type InverterInfo, saveAllCalls } from "../_shared/brands/index.ts";
import { pollJobs } from "../_shared/plants.ts";
import { dayClock, localDate } from "../_shared/localtime.ts";
import { noteError } from "../_shared/errors.ts";

export const TEMP_EVERY_MIN = 10;
export const tempMinute = (sn: string) => [...sn].reduce((h, c) => h + c.charCodeAt(0), 0) % TEMP_EVERY_MIN;
const IN_FLIGHT = 10;

async function pool<T>(n: number, items: T[], work: (t: T) => Promise<void>) {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length) await work(items[i++]);
  }));
}

const bank = async (inv: InverterInfo, version: number | null, rows: Record<string, unknown>[]) =>
  rows.length ? Number(await rpc("q_insert_inverter_history_v2", { p_plant: inv.plantId, p_version: version, p_sn: inv.sn, p_rows: rows }) ?? 0) : 0;

export async function runTemps(ts: number) {
  const out = { inverters: 0, rows: 0, gridHz: 0, failed: 0 };
  const minute = Math.floor(ts / 60);
  try {
    const jobs = await pollJobs(0, 1);
    const jobOf = new Map(jobs.map((j) => [j.plantId, j]));
    const accs = new Map<string, Account>(jobs.map((j) => [j.account.id, j.account]));
    const rows = (await rpc<any[]>("inverters_cached_many", { p_accounts: [...accs.keys()] })) ?? [];
    // a logger that sent something new in the last two minutes: its day so far is worth one call,
    // once, through the login that reads the plant now
    const seen = new Set<string>();
    const due = rows.filter((r) => tempMinute(r.sn) === minute % TEMP_EVERY_MIN && jobOf.has(Number(r.plant_id))
      && jobOf.get(Number(r.plant_id))!.account.id === r.account_id
      && r.last_reading && r.last_reading.carried === false && Number(r.last_reading.ts) >= ts - 120
      && !seen.has(r.sn) && seen.add(r.sn));
    await pool(IN_FLIGHT, due, async (r) => {
      const job = jobOf.get(Number(r.plant_id))!;
      const acc = accs.get(r.account_id) ?? job.account;
      const inv: InverterInfo = { sn: r.sn, plantId: Number(r.plant_id) };
      const b = brandOf(acc.brand);
      try {
        out.rows += await bank(inv, job.version, await b.todayTemps(inv, acc, job.timezone));
        out.inverters++;
        // the first ten-minute turn of each hour also takes today's grid Hz (one call)
        if (minute % 60 < TEMP_EVERY_MIN) {
          const day = localDate(job.timezone);
          const x = await b.history.inverterExtras(acc, inv.sn, day, true);
          out.gridHz += await bank(inv, job.version, b.history.historyRows(x, dayClock(job.timezone, day)));
        }
      } catch (e) {
        out.failed++;
        noteError("temps_failed", e, { plant: inv.plantId!, hourly: true });
      }
    });
  } finally {
    await saveAllCalls();
  }
  return out;
}
