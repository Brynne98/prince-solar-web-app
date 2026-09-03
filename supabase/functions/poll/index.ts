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
} from "../_shared/extract.ts";
import {
  type Account,
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
  error?: string;
  needsRelink?: boolean;
};

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
