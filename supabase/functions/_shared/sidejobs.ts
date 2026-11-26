// The reader's side jobs, each its own cron call of the poll function (SOLAR-681 R18), so the
// every-minute read only reads and saves:
//   task sync   each login's inverter list on its own minute of ten, its plant list (or the
//               share login's list) on its own minute of the hour, and the share login's retry
//   task temps  today's inverter temperatures, each inverter once in ten minutes on its own minute
// Alerts and plant checks run in SQL (private.alerts_minute, private.plant_checks).
import { noteError } from "./errors.ts";
import { db, rpc } from "./db.ts";
import { type Account, brandOf, type InverterInfo, saveAllCalls } from "./brands/index.ts";
import { liveInverters, type PlantJob, pollJobs, shareAccount, shareSync, syncPlants } from "./plants.ts";
import { bankTodayTemps, TEMP_EVERY_MIN, tempMinute } from "./poller.ts";
import { isListMinute, isPlantsMinute } from "../poll/minutes.mts";

const IN_FLIGHT = 10;

/** Runs `work` over `items`, at most `n` at a time. */
async function pool<T>(n: number, items: T[], work: (t: T) => Promise<void>) {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length) await work(items[i++]);
  }));
}

/** The logins that read a plant now, one object each. */
const loginsOf = (jobs: PlantJob[]) => [...new Map(jobs.map((j) => [j.account.id, j.account])).values()];

export async function runSync(ts: number) {
  const out = { lists: 0, plantLists: 0, failed: 0 };
  try {
    // every working login, read now or not: a paused login still finds a plant added at the brand
    const logins = ((await rpc<any[]>("sync_logins", {})) ?? []).map((r): Account => ({
      id: r.id, user_id: r.user_id, username: r.username, brand: r.brand, access_token: r.access_token, access_expires_at: r.access_expires_at,
    }));
    await pool(IN_FLIGHT, logins, async (acc: Account) => {
      try {
        if (isListMinute(acc.id, ts)) {
          const invs = (await liveInverters(acc)).filter((i) => i.plantId != null);
          if (invs.length) await rpc("inverters_seed", { p_rows: invs.map((i) => ({ sn: i.sn, plant_id: i.plantId, account_id: acc.id })) });
          out.lists++;
        }
        if (isPlantsMinute(acc.id, ts)) {
          if (brandOf(acc.brand).isShare(acc)) await shareSync(acc);
          else await syncPlants(acc);
          out.plantLists++;
        }
      } catch (e) {
        out.failed++;
        noteError("plant_sync_failed", e, { user: acc.user_id, hourly: true });
      }
    });
    await retryShareLogin();
  } finally {
    await saveAllCalls();
  }
  return out;
}

// The brand refused the share login: try the secret again an hour after the last try, so
// shared plants restart without an owner pressing Check (SOLAR-451).
async function retryShareLogin() {
  try {
    const { data: id, error } = await db.rpc("share_retry_due");   // 0177
    if (error) throw new Error(error.message);
    if (!id) return;
    try {
      if (await shareAccount()) console.log("share login: signed in again");
    } catch (e) {
      // Logged as another stop, which the next try is timed from. Already stopped, so no email.
      const msg = e instanceof Error ? e.message : String(e);
      await db.rpc("account_mark", { p_account: id, p_status: "needs_reconnect", p_error: msg });
      noteError("share_login_retry_failed", e, { hourly: true });
    }
  } catch (e) {
    noteError("share_login_retry_skipped", e, { hourly: true });
  }
}

export async function runTemps(ts: number) {
  const out = { inverters: 0, rows: 0, failed: 0 };
  const minute = Math.floor(ts / 60) % TEMP_EVERY_MIN;
  try {
    const jobs = await pollJobs(0, 1);
    const jobOf = new Map(jobs.map((j) => [j.plantId, j]));
    const accs = new Map(loginsOf(jobs).map((a) => [a.id, a]));
    const rows = (await rpc<any[]>("inverters_cached_many", { p_accounts: [...accs.keys()] })) ?? [];
    // a logger that sent something new in the last two minutes: its day so far is worth one call,
    // once, through the login that reads the plant now
    const seen = new Set<string>();
    const due = rows.filter((r) => tempMinute(r.sn) === minute && jobOf.has(Number(r.plant_id))
      && jobOf.get(Number(r.plant_id))!.account.id === r.account_id
      && r.last_reading && r.last_reading.carried === false && Number(r.last_reading.ts) >= ts - 120
      && !seen.has(r.sn) && seen.add(r.sn));
    await pool(IN_FLIGHT, due, async (r) => {
      const job = jobOf.get(Number(r.plant_id))!;
      const inv: InverterInfo = { sn: r.sn, plantId: Number(r.plant_id) };
      try {
        out.rows += await bankTodayTemps(inv, accs.get(r.account_id) ?? job.account, job.timezone, job.version);
        out.inverters++;
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
