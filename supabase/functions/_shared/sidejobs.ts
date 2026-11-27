// The reader's side jobs, each its own cron call of the poll function (SOLAR-681 R18), so the
// every-minute read only reads and saves:
//   task sync   each login's inverter list on its own minute of ten, its plant list (or the
//               share login's list) on its own minute of the hour, and the share login's retry
// Alerts and plant checks run in SQL (private.alerts_minute, private.plant_checks).
import { noteError } from "./errors.ts";
import { db, rpc } from "./db.ts";
import { type Account, brandOf, saveAllCalls } from "./brands/index.ts";
import { liveInverters, shareAccount, shareSync, syncPlants } from "./plants.ts";
import { isListMinute, isPlantsMinute } from "../poll/minutes.mts";

const IN_FLIGHT = 10;

/** Runs `work` over `items`, at most `n` at a time. */
async function pool<T>(n: number, items: T[], work: (t: T) => Promise<void>) {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length) await work(items[i++]);
  }));
}

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
