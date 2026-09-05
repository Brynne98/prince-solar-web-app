# SunSynk Dashboard — Data Pipeline & Audit Handoff

**Purpose.** This document captures the hard-won knowledge about how this dashboard reads, stores, and displays solar-inverter data. It is written for an auditor (human or model) tasked with verifying the data is **read, understood, and displayed correctly**. The owner uses this dashboard to make real-world decisions (battery sizing, grid-charge timing), so **accuracy is the priority**.

> Read §3 ("The five traps") first. Most data bugs in this system come from violating one of those five truths. They were each discovered by a wrong assumption that *looked* right in code but failed a physics check.

---

## 1. System under measurement

- **Location:** South Africa. Timezone **SAST = UTC+2**, no DST. All "local day" boundaries use `Africa/Johannesburg`.
- **Inverters:** 2× SunSynk SunC2 Acure 8 kW, wired **master/slave in parallel**.
  - **Master** SN `2508290475` — has the **grid CT** (current clamp) and the **battery BMS comms** (CAN). Reports real grid energy counters and real `bmsSoc`/`bmsVolt`.
  - **Slave** SN `2512082438` — **no grid CT** (its grid energy counters `etodayFrom`/`etotalFrom` read **0**) and **no battery BMS link** (`bmsSoc`/`bmsVolt` read **0**). It still reports its own *instantaneous* grid/battery **power** from its own sensors.
- **Battery:** 5× Eenovance Mana 5.3 kWh modules = **26.5 kWh nominal**, one **shared bank** (~505 Ah at ~52.5 V). BMS per-module limit ~100 A (trips ~110 A). Charge current configured at **75 A/inverter**.
  - The inverter's configured `capacity = 200 Ah` field is an **installer setting, not the real pack size** — ignore it for energy math. Real usable ≈ 26.5 kWh (verified, see §8).
- **Panels:** ~12.6 kWp, observed peak ~9.7 kW. **Each inverter has its own PV strings.**

---

## 2. Architecture

In-browser React (Babel standalone, **no build step** — `.jsx` served raw and compiled client-side), on GitHub Pages. Backend is Supabase: Postgres, pg_cron, and Deno Edge Functions.

```
SunSynk Connect cloud  ──5 realtime endpoints/inverter──┐
(api.sunsynk.net,                                        │
 RSA PKCS#1 login)                                       ▼
                    pg_cron 1/min  → poll               → agg_minute + readings + strings
                    pg_cron 6h     → recover            → agg_minute (source='plantfeed')
                    pg_cron daily  → sync-plant-energy  → plant_energy
                                                           │
  Postgres ────────────────────────────────────────────────┤
   public:  agg_minute (summed plant spine, 1/min)          │
            readings   (per-inverter, 1/min, 30 columns)    │
            strings, plant_energy, app_config               │
   private: auth (SunSynk token), inverters, meta, gaps     ▼
            (NOT exposed to PostgREST)      api_* functions → public/data.jsx → chart/trends/tabs
```

**One acquisition path.** `poll` and `recover` both consume `fetchInverterRaw(sn)` +
`extractReading(inv, raw)` from `_shared/extract.ts` — a single fetch path and a
single field mapping, so they cannot drift apart. (In the monolith these were two
independent implementations that "had to agree"; unified 2026-06-10, and the split
survived the Supabase port intact.)

**Live overview is now a read, not a fetch.** The old `/api/overview` hit all five
SunSynk endpoints per request; `api_overview()` reads the newest logged minute
instead. Up to 60 s staler, and the reason the browser needs no SunSynk credential.

**Credential isolation.** SunSynk username/password exist only as Edge Function
secrets. The derived access token lives in `private.auth`, in a schema PostgREST
does not expose, reachable only through `SECURITY DEFINER` accessors granted to
`service_role`. The publishable key in the public frontend bundle has no route to
any of it — verified by `42501`/`PGRST205` responses, not by assumption.

The 5 per-inverter realtime endpoints (per SN):
```
/api/v1/inverter/grid/{sn}/realtime?sn={sn}          → grid: pac(W,+import), etodayFrom/To, etotalFrom/To, fac, pf
/api/v1/inverter/battery/{sn}/realtime?sn={sn}&lan=en→ battery: power(W,signed), soc, bmsSoc, voltage/bmsVolt, current/bmsCurrent, etodayChg/Dischg
/api/v1/inverter/{sn}/realtime/input                 → pv: pac(W), etoday, etotal, pvIV[] (per-string)
/api/v1/inverter/load/{sn}/realtime?sn={sn}          → load: totalPower(W), dailyUsed, totalUsed  (NOTE: NO 'pac' field)
/api/v1/inverter/{sn}/realtime/output                → output: pac(W), vip[] (per-phase volt/freq)
```
Plant-level history endpoint (used only as fallback, **do not trust for battery/grid** — see §3.2):
```
/api/v1/plant/energy/{plantId}/day?date=YYYY-MM-DD   → series: PV, Battery, SOC, Load, Grid (5-min points)
```

---

## 3. The five traps (read this before auditing anything)

### 3.1 Each inverter measures its OWN quantities; the plant total is the SUM
PV, load, grid, and battery are all measured **per inverter**. Each inverter's readings **balance on their own** (energy in = energy out). The real plant total is `inv1 + inv2`. Verified repeatedly by per-inverter energy balance and the 4am test (§9).

- PV: separate strings → sum is real. ✓
- Load: the parallel pair shares the AC load ~50/50; each reports its half → sum is real. ✓
- Grid: each inverter draws its own grid current → sum is real. ✓
- Battery: shared bank, but each inverter pushes/pulls ~its half and reports that → **sum is real**. ✓

> Counter-intuitive check: at one point both inverters reported *identical* load (621 W = 621 W). That is **balanced 50/50 sharing**, not duplication — the sum (1242 W) is still correct, proven because only the summed value closes the energy balance.

### 3.2 SunSynk's PLANT feed scaling is UNSTABLE — never trust it without calibration
`/api/v1/plant/energy/{plantId}/day` has served this parallel system's series **two different ways**:

- **During the original audit (early June 2026):** Load and PV as the full sum, but **Battery and Grid as a SINGLE inverter (~half)** — its series did not balance (e.g. an 8 kW geyser load next to a 4 kW battery with no sun/grid — impossible). This is what corrupted the backfill (§7.3).
- **As of 2026-06-10:** ALL series come back as the **full plant sum** (verified against logged overlap on multiple days and power levels — battery, grid, load all ratio ≈ 1.0 vs `agg_minute`; the old `×2` would have doubled them).

SunSynk evidently changed the feed server-side. Consequences:

- The day chart still sources from our **own `agg_minute`** (`db.dayAgg()` in `getHistory`) — that hasn't changed and never will.
- Wherever the feed *is* used (gap dot-fill, pre-logging fallback), it is scaled by **empirical calibration** (`calibrateFeedScale`): median of real/feed over buckets where the logger and feed overlap, per series, with grid borrowing battery's scale when grid was inactive. Never a hardcoded multiplier — it auto-adapts if SunSynk flips behavior again.
- **Nothing in this system is "doubled."** An earlier "doubling" theory was wrong then; ironically, a hardcoded ×2 *would* double things today.

### 3.3 Battery sign: ONE internal convention, flipped only at two boundaries
| Place | Convention |
|---|---|
| SunSynk API `battery.power` (raw) | **positive = DISCHARGING** (this firmware; set by `BATTERY_POSITIVE_MEANS='discharging'` in `.env`) |
| **Everything internal** — `readings.batt_w`, `agg_minute.batt_w`, `getInverterSnapshot().battery.signedPower`, Overview totals | **positive = CHARGING**. Normalized in exactly one place: `extractReading()` (`battSigned = -raw`). |
| `getHistory()` chart series `"Battery"` | **negative = charging** (legacy SunSynk/chart convention) — the ONLY remaining flip, applied at the emit boundary (`-batt_w`) |

The raw firmware convention survives only in the stored `readings.batt_power_w` column (kept for audit) and the raw gzip payloads. Grid sign is consistent everywhere: **positive = import, negative = export.**

A correct row therefore satisfies: **`batt_w > 0` ⟺ SOC rising** (charging). Any row violating this is a sign bug (this is exactly how the backfill corruption was caught — see §7).

### 3.4 Energy COUNTERS are gap-immune; power INTEGRALS are not
The inverters integrate `etoday*`/`etotal*` (kWh) continuously on their own hardware. Polling only *samples* them. So:
- **Energy over any window = counter(end) − counter(start)** is exact **even if the laptop slept** through the middle. Verified across a 3.6 h gap: counters recovered PV 6.5 / load 0.4 / battChg 6.2 kWh with zero power samples logged.
- **Integrating per-minute power** (`Σ W·dt`) **under-counts whenever there is a gap** (the laptop sleeps and the poller misses minutes). ~Half the days currently have gaps.
- Per-inverter PV/load/battery counters: each reports its own → **sum = real, gap-free**.
- **Grid counter exception:** the slave's grid counter reads 0 (no CT), so summing counters gives **master-only (~half)**. Grid energy cannot be made exact from counters; best gap-free estimate is `2 × master`. The live integral counts both but is gap-sensitive.

### 3.5 `localtime` and day boundaries are SAST
Daily grouping and today-calcs are anchored to `Africa/Johannesburg`, not the caller's timezone. In Postgres this is the `local_day(ts)` / `local_hour(ts)` / `local_ts(ts)` helpers — `IMMUTABLE`, so `agg_minute_day_idx` can be built on `local_day(ts)`. The legacy SQLite path used `strftime(..., 'unixepoch', 'localtime')`, which depended on the *host* timezone; pinning the zone explicitly was part of the port, and is why the two agree. An auditor in another timezone must account for this when spot-checking "today".

---

## 4. Field mapping (what each stored column comes from)

`extractReading()` is the single mapping (the snapshot consumes it too). `pick(obj, ...keys)` = first non-null key; power fields go through `powerField()` (see footgun note below).

| Stored (readings) | Source field(s) | Notes |
|---|---|---|
| `pv_w` | `input.pac` \|\| `solarPower` \|\| `sumVip(input)` | W |
| `grid_w` | `grid.pac` \|\| `sumVip(grid)` | W, **+import / −export** |
| `load_w` | `load.pac` \|\| `load.totalPower` \|\| `sumVip(load)` | load has **no `pac`** → uses `totalPower`. (`totalUsed` was removed from this chain — it's a **kWh counter**, not power.) |
| `batt_power_w` | `battery.power` (raw) | +discharge (firmware) |
| `batt_w` | `−battery.power` | **normalized +charge** |
| `batt_soc` | `battery.soc` \|\| `bmsSoc` | % |
| `batt_voltage_v`/`_current_a`/`_temp_c` | `voltage`/`current`/`temp` \|\| `bms*` | temp may contain junk (e.g. −100) → filter on read |
| `pv_today_kwh` / `pv_total_kwh` | `input.etoday` / `etotal` | per-inverter cumulative |
| `grid_import_today_kwh` etc. | `grid.etodayFrom/To`, `etotalFrom/To` | **slave = 0** |
| `batt_chg_today_kwh` etc. | `battery.etodayChg/Dischg`, `etotal*` | per-inverter cumulative |
| `load_today_kwh` / `load_total_kwh` | `load.dailyUsed` / `totalUsed` | per-inverter |

`agg_minute` (the summed plant spine, `collectAndLog` ~L869):
- `pv_w/load_w/batt_w/grid_w` = **Σ over inverters** of the readings field.
- `soc` = **average** of the inverters' `batt_soc` (rounded). (Fine for a shared/balanced bank; note it's an average, not a sum.)

> **Footgun (FIXED 2026-06-10):** the old `|| sumVip(...)` fallbacks fired when the primary field was **falsy including legitimate 0**. Power fields now use `powerField()`, which falls back to `sumVip` only when the primary field is absent (`null`/`undefined`/`''`) — a real 0 W stays 0.

---

## 5. Storage

Supabase Postgres. `public`: `agg_minute` (1/min summed, with `source` provenance column), `readings` (1/min per-inverter, PK `(ts,sn)`, 30 columns), `strings`, `plant_energy` (cached plant kWh totals), `app_config` (solar-model constants). `private`, not exposed to PostgREST: `auth` (SunSynk token), `inverters`, `meta`, `gaps` (logger-offline windows). The chart reads `agg_minute` via `q_day_agg(date)` (5-min buckets, `AVG` per bucket), re-gridded by `api_history` onto the full 5-min day with `null` for missing buckets.

- The `poll` Edge Function writes `readings` + `strings` + `agg_minute` together every minute, stamping `agg_minute.source = 'poller'`. Provenance is explicit in the row, not inferred by joining against `readings`. Since migration `0030` the whole minute for an account goes through one `poll_commit()` call, so it lands in a single transaction (readings and strings last-write-wins, `agg_minute` first-write-wins, the logger-offline gap recorded in the same statement). The cron job fans `poll` out into shards of ~10 accounts (`private.poll_shards()`), each invocation staggered 0/10/20 s into the minute so the fleet does not hit SunSynk at second zero; an account always hashes to the same shard. Since `0031` the inverter and plant lists are re-read from SunSynk only on minutes divisible by 10 and served from `private.inverters` + `private.meta` (`inverters_cached()`) in between, and every `readings` row carries `device_time`, the inverter's own upload timestamp from `pvIV[0].time` — the field that separates a fresh sample from a repeat of the previous one (the slave uploads every 5 minutes). Each poll response reports `apiCalls` and `listRefreshed` per account so the request budget is measurable from the cron log.
- **Backfill code is DELETED** (2026-06-10; it had been disabled-but-present). It used to seed `agg_minute` from the plant feed (§3.2) → half values + inverted battery sign, and re-filled poller gaps on every restart. See §7. The poller is the only writer of `source='poller'` rows.
- **Gap tracking:** when a poll lands > 90 s after the previous row, the offline window is recorded in `private.gaps` (historical gaps were seeded once from `agg_minute` timestamp jumps). `q_day_gap_minutes(date)` powers the day chart's "missing" badge.
- **Cloud gap recovery:** logger-offline minutes are banked from SunSynk's cloud feed into `agg_minute` tagged `source='plantfeed'` (calibrated per §3.2, `ON CONFLICT DO NOTHING` so a poller row always wins, live edge of 10 min left to the poller). Runs every 6 h. Reversible: `DELETE FROM agg_minute WHERE source='plantfeed'`. Recovered minutes are first-class history for metrics, render DOTTED in the chart, and are EXCLUDED from the §9 integrity audit (they're estimates, not pipeline measurements). First sweep recovered all 1,547 missing minutes; recovered-day PV integrals then matched the hardware counters within ~1% (§9E).
  - **Changed in the Supabase port:** `recover` sweeps a rolling 14-day window rather than all history, because the cloud only retains ~1–2 weeks — scanning 60+ days spent API calls on days that can never return data. Days outside the window are reported in the response as `notScanned` rather than silently skipped. The opportunistic "recover when a day with holes is viewed" path is also gone: reads are now pure Postgres functions with no side effects, so recovery happens only on its schedule.
- Local logging started **2026-05-30 16:44 SAST**. Earlier days are not stored; `api_history` returns `approx: true` with an empty series for them, and the day picker's lower bound comes from `api_history_earliest`.
- **Not migrated from SQLite:** the `raw` table (gzipped full payloads). It was 46 MB of the old 96 MB file, had no consumer, and was a place account identifiers could hide. `api_db_stats` therefore reports its counters as 0.

---

## 6. Display layer (`public/`)

- `data.jsx` — API→UI mapping. `aggregate()` builds the Overview totals: `pvToday`/`battChgToday`/`battDischgToday`/`loadToday` are **summed** from per-inverter counters (gap-free ✓). `gridFromToday` comes from the server's `todayGridImport`, which is now computed from the logger (see §7, item 2).
- `chart.jsx` — day chart + drag-to-total range select. Consumes `getHistory` series (a full 5-min grid; `null` = no data anywhere, `est:true` = cloud-recovered bucket, §5). All data renders uniformly (owner preference — no dotted/shaded styling); provenance shows via one badge ("Xm missing" = `gapMinutes + recoveredMinutes`, i.e. everything the local logger missed whether or not the cloud recovered it), the hover tooltip ("≈ SunSynk estimate"), and the `est` flag in the API. Lines/fills break only at `null` buckets. Totals/range include recovered minutes (they're history, tagged). Battery shown with **negative = charging** (§3.3). Shows "≈ estimated" badge when `dayData.approx`.
- `trends.jsx` — battery (per-segment usage split via `segmentPower`, energy-scaled bars by source) + energy cards. Integrates `agg_minute` → gap-sensitive, but gaps are now cloud-recovered (§5). **Removed 2026-06:** the "wasted/surplus solar" feature and the overnight "battery at midnight" phase card (`overnightModel`/`/api/overnight`) — unmeasurable estimates / obsoleted by the grid-backstop floor. The honest replacements: the per-segment battery/grid split (kWh, energy-scaled bars with a chart-style hover tooltip showing each source's % of the segment) + the banner's "hours at full" (a measured curtailment signal). **The clear-sky `potentialProfile` / dotted chart line was kept/re-added** as a *visual-only* reference (no legend pill, value shown in the day-chart tooltip) — `clearSkyShape`/`solarScaleW`/`/api/trends/potential` — but no kWh is derived from it (curtailed solar stays unmeasurable).
- `tabs.jsx` — Live tab; `BatteryBalanceBanner` polls `/api/balance` (per-inverter SOC/voltage spread = desync monitor).

---

## 7. Bugs found & fixed (audit history — already addressed)

1. **Day chart used the plant feed** → battery/grid at half, didn't balance. **Fixed:** `getHistory` now builds from `agg_minute` (`db.dayAgg`), with sign flip `Battery = -batt_w`. Plant feed kept only as `approx` fallback for pre-logging days.
2. **Overview "imported today" under-counted grid** — it summed per-inverter `todayImport`, but the slave reads 0. **Fixed:** `gridTodayFromLog()` integrates today's `agg_minute.grid_w` (counts both inverters). *Caveat:* this is gap-sensitive (the only daily tile that is).
3. **Backfill corruption.** `backfillDay` seeded `agg_minute` from the plant feed → battery **sign-inverted** (negative while SOC rising) and **half** grid/battery; it also re-filled poller gap-minutes on every restart. **Fixed:** disabled `backfillRecent()`; defensively corrected `backfillDay` battery sign (`-at('batt')`); **deleted 1,666 corrupt backfill-only rows** (backup at `data/sunsynk.db.bak-pre-cleanup`). Post-cleanup every day balances to ~80–115 W (was 2,000–4,700 W on seed days).
4. **`load_w` footgun** — fallback chain included `totalUsed` (a kWh counter). **Fixed:** removed; chain is now power-only (`pac`, `totalPower`).
5. **`data.jsx` day-totals battery sign** was backwards. **Fixed.**
6. **Orphaned geyser code** removed (`analyzeGeyserWindow`, `geyserReport`, `/api/trends/geyser`, `fetchGeyser`). The overnight model's "geyser→dawn" phase is unrelated and **kept**.
7. *(2026-06-10)* **Acquisition paths unified** — `getInverterSnapshot` now consumes `extractReading` via shared `fetchInverterRaw`; the field mapping exists once (§2).
8. *(2026-06-10)* **Battery sign collapsed to one internal convention** (+ = charging, normalized only in `extractReading`; chart flip only at `getHistory`). `snapshot.battery.signedPower` changed meaning from raw to normalized — no frontend consumer used it signed (§3.3).
9. *(2026-06-10)* **Backfill code deleted** (`backfillDay`/`backfillRecent`/`insertAggMany`) — it was disabled but one uncomment away from re-corrupting history.
10. *(2026-06-10)* **`|| sumVip` falsy-zero footgun fixed** with `powerField()` (§4).
11. *(2026-06-10)* **Gaps made visible** — `getHistory` emits a full 5-min grid with `null` buckets + `gapMinutes`; the chart breaks lines, shades gaps, shows a "missing" badge. (Previously the time axis silently compressed and lines were drawn across gaps — x-tick labels were also misplaced on gappy days.)
12. *(2026-06-10)* **Surplus per-day weighting fixed** — was `Σgap × 24/N` (over-scales gappy days); now integrates real sample spacing capped at 10 min. *(Superseded — the whole surplus feature was removed 2026-06; see §6.)*
13. *(2026-06-10)* **§9A/§9B automated** — `db.integrityReport()`, `/api/integrity`, nightly server check, `npm run check` CLI.
14. *(2026-06-10)* **Gap dot-fill added + feed scale instability discovered.** Logger-offline windows are now dot-filled in the chart from SunSynk's cloud feed. Validating the fill revealed the plant feed NOW serves full-sum battery/grid (it served ~half during the original audit — §3.2 rewritten). All feed use goes through empirical per-series calibration instead of any hardcoded multiplier.
15. *(2026-06-10)* **Cloud gap recovery.** Missing minutes are banked into `agg_minute` as `source='plantfeed'` (§5) — all 1,547 historical gap minutes recovered, verified against counters (~1%). Recovered rows are first-class for metrics, dotted in the chart, excluded from the integrity audit.

---

## 8. Known residual issues (verify / decide)

1. **Data gaps when the laptop sleeps** (owner runs it on a laptop, not 24/7). LARGELY MITIGATED (2026-06-10) by cloud gap recovery (§5): past gaps are back-filled from SunSynk's feed within ~6 h, so integral metrics (overnight kWh, per-segment usage, grid-today, range totals) now see a continuous series. Residual exposure: (a) recovered minutes are calibrated 5-min estimates, not 1-min measurements — per-inverter `readings` detail for those minutes is gone forever; (b) a gap only survives permanently if the laptop stays off longer than the cloud's retention (~1–2 weeks). Running 24/7 (launchd + `pmset -c disablesleep 1`) remains the complete answer.
2. **Grid energy can never be made exact** while the slave CT is absent: counters give master-only (~half); `2×master` is the best gap-free estimate; the integral counts both but was gap-sensitive (now self-healing via cloud recovery). **DECIDED 2026-06-10:** the grid-today tile stays integral-based (accurate to ~1% with recovery; the counter isn't more accurate, just differently uncertain). Instead, the integrity report cross-checks integral vs `2×master etotalFrom delta` on every import day and flags `grid-xcheck` at >15% divergence — continuously re-validating the 50/50 sharing assumption.
   - **`2×master` VALIDATED 2026-06-10** against the both-inverter integral on the only two days with real import: 2026-06-03 (gap-free): 11.2 vs 10.96 kWh (+2%); 2026-06-05: 23.2 vs 23.26 kWh (−0.3%). The ~50/50 sharing holds for grid draw. (Small sample — only two import days so far; re-check as more accumulate.)
   - **Counter trap found during validation:** the master's *daily* counter `etodayFrom` resets shortly *after* midnight, not at it — the first poll(s) of a new day can still carry yesterday's value (e.g. 5.5 kWh at 00:0x on 06-04). For day-bucketed math use **lifetime `etotalFrom` deltas**, never `MAX(etodayFrom)` per day.
3. **`agg_minute.soc` is an average** of the two inverters' SOC, not a sum — correct for a shared bank, but note it.

*(Resolved since the last audit: two-sign-convention fragility → collapsed to one internal convention (§3.3); `|| sumVip` falsy-zero footgun → `powerField()` (§4).)*

---

## 9. Validation playbook (physics, not code-reading)

> **§9A and §9B are now automated:** `npm run check` (CLI, exits non-zero on a flagged day), `GET /api/integrity`, and a nightly in-server run that logs flagged days. The manual SQL below remains the reference for diagnosis.

Run these against `./data/sunsynk.db`. **`batt_w > 0 = charging`, `grid_w > 0 = import`.** Expect conversion losses, so "balanced" means residual ≲ ~150 W (instantaneous) or within a few % (daily).

**A. Per-row energy balance** (the master check):
```
in  = pv_w + max(0, grid_w) + max(0, -batt_w)      // sources: solar, grid import, battery discharge
out = load_w + max(0, -grid_w) + max(0, batt_w)     // sinks: house, grid export, battery charge
residual = in - out   // should be small; large = sign error, half-value, or unit bug
```
Bucket residual by day. Backfill/seed corruption shows up as multi-kW residuals on specific days.

**B. Battery sign vs SOC:** for consecutive rows with `|batt_w|>300` and SOC changing, `batt_w>0` must coincide with SOC rising. Disagreement = inverted sign (the backfill bug signature).

**C. Capacity coulomb-count** (must use a **gap-free** night, else it's confounded): over a clean overnight discharge, `battery_discharge_kWh / SOC_drop% × 100 ≈ 26.5 kWh`. (Jun 7, full data: 46% = 12.18 kWh → 26.5 ✓. Gappy nights gave 4 kWh nonsense — that's the gap, not capacity.)

**D. Per-inverter internal balance:** at night (pv=0, grid≈0), each inverter's `load_w ≈ −batt_w` (it serves its load from its own battery). Confirms per-inverter measurement (§3.1).

**E. Counter vs integral cross-check:** on a **no-gap** day, `Σ(agg_minute power · dt)` should match the per-inverter **counter delta** (`etoday` end − start, summed). Divergence on gappy days quantifies the gap loss.

**F. The 4am geyser test:** find a pre-dawn geyser run (no sun, no grid). `load_w` must equal `−batt_w` (battery discharge). If the chart shows load ≫ battery, the battery series is being under-reported (the original plant-feed bug).

**G. Ground-truth cross-checks vs SunSynk's own app:** the app's **energy/stats tiles** (kWh) are trustworthy per-inverter; its **power-flow graph doubles/halves** for parallel systems, so it disagrees with its own meter — trust the meter, not the graph.

---

## 10. Ground-truth values for THIS system (sanity anchors)

- Battery usable capacity ≈ **26.5 kWh** (~505 Ah @ ~52.5 V).
- Master SN `2508290475`: real grid meter (`todayImport` non-zero, `totalImport` grows). Slave SN `2512082438`: `todayImport`/`totalImport`/`bmsSoc`/`bmsVolt` = **0**.
- A correct full day roughly balances: `PV + grid_import + batt_discharge ≈ load + grid_export + batt_charge` (± conversion loss). Example clean day: PV ~39, load ~37, grid_import ~9, batt chg ~29 / dis ~19 kWh.
- Panels peak ~9.7 kW; battery charge capped ~75 A/inverter.
- Logging window: **2026-05-30 16:44 SAST → present**; earlier days = live `approx` fallback only.

---

## 11. Suggested audit order

1. `npm run check` (= §9A + §9B + gap report) → confirm every day balances (post-cleanup it should; if not, new corruption).
2. Run §9C on a no-gap night → confirm ~26.5 kWh.
3. Trace one value end-to-end: raw endpoint → `extractReading` → `agg_minute` → `getHistory` → `chart.jsx` rangeSummary, watching the **battery sign flip** at `getHistory` and the **grid/battery summing**.
4. Confirm `getHistory` never serves the plant feed for a day that has `agg_minute` data (the plant feed is fallback-only), and that missing buckets arrive as `null` (not 0) with a correct `gapMinutes`.
5. Review §8 residuals and decide which to fix.

---

*Maintained alongside the code. If you change sign conventions, summing, or the chart data source, update §3 and §4 — those are the load-bearing facts.*
