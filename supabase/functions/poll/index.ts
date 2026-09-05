// `poll` — the per-minute logger, now per linked account.
//
// pg_cron fires this every minute. For each active SunSynk account it fetches every
// inverter's 5 realtime endpoints, maps them with the shared extractReading(), and
// stores per-inverter readings + per-string PV + metadata + a summed row per plant
// on the aggregate spine.
//
// An account whose refresh token has died (password changed, token revoked) is
// marked needs_relink and skipped; the others continue. Any other per-account
// failure is recorded on the row and the account stays active for the next tick.
//
// Deliberately NOT ported: the gzipped `raw` payload table. It was 46 MB of the
// 96 MB SQLite file, has no dashboard consumer, and may embed account identifiers.
import {
  aggregate,
  extractMeta,
  extractReading,
  extractStrings,
  type InverterInfo,
  realtimePaths,
} from "../_shared/extract.ts";
import {
  type Account,
  apiGet,
  db,
  ensureBootstrapAccount,
  fetchInverterRaw,
  getInverters,
  RelinkNeeded,
} from "../_shared/sunsynk.ts";

/** epoch seconds for the current minute — the dedup key for a sample */
const nowMinuteEpoch = () => Math.floor(Date.now() / 60000) * 60;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

async function rpc(fn: string, args: Record<string, unknown>) {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

type AccountResult = {
  account: string;
  inverters: number;
  readings: number;
  strings: number;
  plants: number[];
  gapRecorded: number[];
  burst?: string;
  error?: string;
  needsRelink?: boolean;
};

// ---------------------------------------------------------------------------
// Grid burst: sub-minute samples after a relay-open / low-voltage minute.
//
// The one relay-open minute on record (2026-09-04 11:15) was sampled AFTER the
// utility had returned -- grid_volt_v and output_volt_v, identical with the relay
// closed, differed by 12.9 V, so the grid-side sensor was seeing live mains while the
// inverter sat in its reconnect delay. The dead-grid interval fell between polls.
// Nothing logged so far shows what this firmware reports while the grid is actually
// OFF, which is the fact 0017's alert wording is waiting on.
//
// So when a poll sees the trigger, take BURST_SAMPLES more readings at
// BURST_SPACING_MS, grid + output endpoints only, and store them in grid_burst
// (migration 0029). Bounded to finish before the next minute's poll, which re-arms
// if the relay is still open -- so an event of any length gets ~10 s coverage with
// no overlap and no unbounded work.
//
// Runs after the response via EdgeRuntime.waitUntil, so the burst never delays the
// minute's normal write and pg_cron's 50 s wait is unaffected.
// ---------------------------------------------------------------------------
const BURST_SAMPLES = 5;
const BURST_SPACING_MS = 10_000;
const BURST_BUDGET_MS = 55_000; // hard stop: the next poll starts at +60 s
const LOW_VOLT_V = 100;         // same threshold as q_grid_present()

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Why a reading triggers a burst, or null if it doesn't. */
function burstTrigger(r: Record<string, unknown>): "relay_open" | "low_volt" | null {
  if (r.grid_relay_status === "0") return "relay_open";
  const v = r.grid_volt_v;
  if (typeof v === "number" && v < LOW_VOLT_V) return "low_volt";
  return null;
}

async function burstGrid(
  acc: Account, inverters: InverterInfo[], triggerTs: number, trigger: string,
): Promise<void> {
  const started = Date.now();
  let stored = 0;
  for (let i = 0; i < BURST_SAMPLES; i++) {
    if (i > 0) await sleep(BURST_SPACING_MS);
    if (Date.now() - started > BURST_BUDGET_MS) break;
    const ts = Math.floor(Date.now() / 1000);

    // Grid + output only: the two sensors that straddle the relay. Every inverter on
    // the account, not just the one that tripped -- the slave's stale feed is part
    // of what needs observing.
    const rows = await Promise.all(inverters.map(async (inv) => {
      const paths = realtimePaths(inv.sn);
      const [grid, output] = await Promise.all([
        apiGet(paths.grid, acc).catch(() => null),
        apiGet(paths.output, acc).catch(() => null),
      ]);
      const r = extractReading(inv, { grid, output, battery: null, input: null, load: null });
      return {
        ts, sn: inv.sn, plant_id: inv.plantId ?? null, trigger, trigger_ts: triggerTs,
        grid_volt_v: r.grid_volt_v, grid_relay_status: r.grid_relay_status,
        grid_freq_hz: r.grid_freq_hz, grid_w: r.grid_w,
        output_volt_v: r.output_volt_v, output_freq_hz: r.output_freq_hz,
      };
    }));
    const withPlant = rows.filter((r) => r.plant_id != null);
    if (!withPlant.length) continue;
    const ins = await db.from("grid_burst").upsert(withPlant, { onConflict: "ts,sn" });
    if (ins.error) { console.warn("grid_burst:", ins.error.message); continue; }
    stored += withPlant.length;
  }
  console.log(`grid burst (${trigger} @ ${triggerTs}): ${stored} rows in ${Date.now() - started} ms`);
}

/** Run after the response if the runtime supports it; otherwise inline (local dev). */
function background(p: Promise<void>) {
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(p);
  else return p;
}

async function pollAccount(acc: Account, ts: number): Promise<AccountResult> {
  const result: AccountResult = {
    account: acc.id, inverters: 0, readings: 0, strings: 0, plants: [], gapRecorded: [],
  };

  const inverters = await getInverters(acc);
  if (!inverters.length) return result;
  result.inverters = inverters.length;

  const perInv = await Promise.all(
    inverters.map(async (inv) => ({ inv, raw: await fetchInverterRaw(inv.sn, acc) })),
  );

  const readings = perInv.map(({ inv, raw }) => ({
    ts, plant_id: inv.plantId ?? null, ...extractReading(inv, raw),
  }));
  const strings = perInv.flatMap(({ inv, raw }) =>
    extractStrings(inv, raw).map((s) => ({ ts, plant_id: inv.plantId ?? null, ...s }))
  );
  const meta = perInv.map(({ inv, raw }, i) => extractMeta(inv, raw, ts, i));

  // Rows with no plant can't be attributed to a user; drop them rather than store
  // orphans that RLS would hide forever.
  const withPlant = readings.filter((r) => r.plant_id != null);
  const stringsWithPlant = strings.filter((s) => s.plant_id != null);

  // One aggregate row per plant on this account.
  const plantIds = [...new Set(withPlant.map((r) => r.plant_id as number))];
  result.plants = plantIds;

  for (const plantId of plantIds) {
    const agg = aggregate(withPlant.filter((r) => r.plant_id === plantId) as any);

    // Logger-offline detection, same rule as db.js recordPoll(): this poll landing
    // more than 90 s after the previous row for this plant means the minutes between
    // were never sampled. Record the window so `recover` can backfill it.
    const { data: prevRow } = await db
      .from("agg_minute").select("ts").eq("plant_id", plantId)
      .order("ts", { ascending: false }).limit(1).maybeSingle();
    const prev = prevRow?.ts ? Number(prevRow.ts) : null;
    if (prev !== null && ts - prev > 90) {
      try {
        await rpc("gap_record", { p_plant: plantId, p_from: prev, p_to: ts });
        result.gapRecorded.push(plantId);
      } catch (e) {
        console.warn("gap_record failed:", e instanceof Error ? e.message : e);
      }
    }

    // agg_minute is INSERT OR IGNORE — first write for a minute wins.
    const aggIns = await db
      .from("agg_minute")
      .upsert({ plant_id: plantId, ts, ...agg, source: "poller" },
              { onConflict: "plant_id,ts", ignoreDuplicates: true });
    if (aggIns.error) throw new Error(`agg_minute: ${aggIns.error.message}`);
  }

  // readings/strings are INSERT OR REPLACE — last write wins.
  if (withPlant.length) {
    const rdIns = await db.from("readings").upsert(withPlant, { onConflict: "ts,sn" });
    if (rdIns.error) throw new Error(`readings: ${rdIns.error.message}`);
    result.readings = withPlant.length;
  }
  if (stringsWithPlant.length) {
    const stIns = await db.from("strings").upsert(stringsWithPlant, { onConflict: "ts,sn,no" });
    if (stIns.error) throw new Error(`strings: ${stIns.error.message}`);
    result.strings = stringsWithPlant.length;
  }

  // meta and the inverter mirror live in `private`, reached via the accessors.
  await rpc("meta_upsert", { p_rows: meta });
  await rpc("inverters_seed", {
    p_rows: inverters.map((i) => ({ sn: i.sn, plant_id: i.plantId ?? null, account_id: acc.id })),
  });
  await rpc("account_access_set", {
    p_account: acc.id, p_access: acc.access_token, p_expires: acc.access_expires_at,
  });

  // Relay open or mains voltage gone on any inverter: start the sub-minute burst.
  const trigger = withPlant.map(burstTrigger).find((t) => t !== null) ?? null;
  if (trigger) {
    result.burst = trigger;
    const p = burstGrid(acc, inverters, ts, trigger)
      .catch((e) => console.warn("grid burst failed:", e instanceof Error ? e.message : e));
    await background(p);
  }

  return result;
}

Deno.serve(async () => {
  try {
    // First run after deploy: link the env-credential account so logging never stops.
    try {
      await ensureBootstrapAccount();
    } catch (e) {
      console.warn("bootstrap skipped:", e instanceof Error ? e.message : e);
    }

    const accounts = (await rpc("accounts_active", {})) as Account[];
    if (!accounts?.length) return json({ ok: true, ts: nowMinuteEpoch(), accounts: 0, note: "no active accounts" });

    const ts = nowMinuteEpoch();
    const results: AccountResult[] = [];

    // Accounts are independent; one dying must not stop the others.
    for (const acc of accounts) {
      try {
        results.push(await pollAccount(acc, ts));
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        if (e instanceof RelinkNeeded) {
          await rpc("account_mark", { p_account: acc.id, p_status: "needs_relink", p_error: msg }).catch(() => {});
          results.push({ account: acc.id, inverters: 0, readings: 0, strings: 0, plants: [], gapRecorded: [], error: msg, needsRelink: true });
        } else {
          await rpc("account_mark", { p_account: acc.id, p_status: "active", p_error: msg }).catch(() => {});
          results.push({ account: acc.id, inverters: 0, readings: 0, strings: 0, plants: [], gapRecorded: [], error: msg });
        }
        console.error(`poll: account ${acc.id} failed:`, msg);
      }
    }

    const ok = results.filter((r) => !r.error);
    return json({
      ok: ok.length > 0,
      ts,
      accounts: accounts.length,
      succeeded: ok.length,
      inverters: ok.reduce((n, r) => n + r.inverters, 0),
      readings: ok.reduce((n, r) => n + r.readings, 0),
      strings: ok.reduce((n, r) => n + r.strings, 0),
      results,
    }, ok.length > 0 ? 200 : 502);
  } catch (e) {
    console.error("poll failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
