// `poll` — the per-minute logger. pg_cron fires this; it replaces
// setInterval(tick, 60_000) in server.js.
//
// Mirrors collectAndLog() + db.recordPoll() from the monolith: fetch every
// inverter's 5 realtime endpoints, map them with the shared extractReading(), and
// store per-inverter readings + per-string PV + metadata + a summed row on the
// aggregate spine.
//
// Deliberately NOT ported: the gzipped `raw` payload table. It was 46 MB of the
// 96 MB SQLite file, has no dashboard consumer, and may embed account identifiers.
import {
  aggregate,
  extractMeta,
  extractReading,
  extractStrings,
} from "../_shared/extract.ts";
import { db, fetchInverterRaw, getInverters } from "../_shared/sunsynk.ts";

/** epoch seconds for the current minute — the dedup key for a sample */
const nowMinuteEpoch = () => Math.floor(Date.now() / 60000) * 60;

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async () => {
  try {
    // The monolith re-reads the inverter list every tick, and readings depend on it
    // (status) as does meta (alias/model/firmware). Keep that; the cached
    // private.inverters table is a mirror for other callers, not the source here.
    const inverters = await getInverters();
    if (!inverters.length) return json({ error: "no inverters returned by SunSynk" }, 502);

    const perInv = await Promise.all(
      inverters.map(async (inv) => ({ inv, raw: await fetchInverterRaw(inv.sn) })),
    );

    const ts = nowMinuteEpoch();
    const readings = perInv.map(({ inv, raw }) => ({ ts, ...extractReading(inv, raw) }));
    const strings = perInv.flatMap(({ inv, raw }) =>
      extractStrings(inv, raw).map((s) => ({ ts, ...s }))
    );
    const meta = perInv.map(({ inv, raw }, i) => extractMeta(inv, raw, ts, i));
    const agg = aggregate(readings);

    // Logger-offline detection, same rule as db.js recordPoll(): this poll landing
    // more than 90 s after the previous row means the minutes between were never
    // sampled. Record the window so `recover` can backfill it from the cloud.
    const { data: prevRow } = await db
      .from("agg_minute").select("ts").order("ts", { ascending: false }).limit(1).maybeSingle();
    const prev = prevRow?.ts ? Number(prevRow.ts) : null;
    if (prev !== null && ts - prev > 90) {
      const { error } = await db.rpc("gap_record", { p_from: prev, p_to: ts });
      if (error) console.warn("gap_record failed:", error.message);
    }

    // agg_minute is INSERT OR IGNORE in SQLite — first write for a minute wins.
    const aggIns = await db
      .from("agg_minute")
      .upsert({ ts, ...agg, source: "poller" }, { onConflict: "ts", ignoreDuplicates: true });
    if (aggIns.error) throw new Error(`agg_minute: ${aggIns.error.message}`);

    // readings/strings are INSERT OR REPLACE — last write wins.
    const rdIns = await db.from("readings").upsert(readings, { onConflict: "ts,sn" });
    if (rdIns.error) throw new Error(`readings: ${rdIns.error.message}`);

    if (strings.length) {
      const stIns = await db.from("strings").upsert(strings, { onConflict: "ts,sn,no" });
      if (stIns.error) throw new Error(`strings: ${stIns.error.message}`);
    }

    // meta and the inverter mirror live in `private`, reached via the accessors.
    const metaRes = await db.rpc("meta_upsert", { p_rows: meta });
    if (metaRes.error) throw new Error(`meta_upsert: ${metaRes.error.message}`);

    const seedRes = await db.rpc("inverters_seed", {
      p_rows: inverters.map((i) => ({ sn: i.sn, plant_id: i.plantId ?? null })),
    });
    if (seedRes.error) console.warn("inverters_seed failed:", seedRes.error.message);

    return json({
      ok: true,
      ts,
      inverters: inverters.length,
      readings: readings.length,
      strings: strings.length,
      gapRecorded: prev !== null && ts - prev > 90,
    });
  } catch (e) {
    console.error("poll failed:", e);
    return json({ error: String(e instanceof Error ? e.message : e) }, 500);
  }
});
