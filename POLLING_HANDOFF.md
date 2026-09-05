# Polling optimisation — handoff

Written 5 Sep 2026. Self-contained: a fresh session can start from here without the
conversation that produced it. Read `DATA_PIPELINE.md` §1–2 and `API.md` ("Endpoint
survey — 5 Sep 2026") alongside.

## 1. Goal

Prince Solar is going multi-tenant and paid. The minute logger (`supabase/functions/poll`)
is the only thing that scales with customers, and SunSynk's API is the ceiling: every
inverter costs five HTTP requests a minute. The goal is to fetch **as little as possible
while every number a user sees, and every alert, is as fresh as SunSynk can make it.**

SunSynk's written position (email, Sep 2026): "one poll per minute per inverter is
fine, there shouldn't be any issues with rate limits." Whether they count our five
endpoint calls as one poll was not clarified; treat per-minute polling as approved and
the five-call fan-out as the thing to shrink.

## 2. What is already done (all in production, branch `feat/free-customers`)

| Change | Where | Effect |
|---|---|---|
| Sharded poll fan-out; each account's minute committed in one transaction | migration `0030`, `poll/index.ts`, `poll_commit()` | scales past ~15 accounts; no half-written minutes |
| Retry 429 (and 403 only when the gateway says throttled) | `_shared/sunsynk.ts` `apiGet` | a burst no longer loses the minute |
| Inverter + plant lists from cache, refreshed every 10 min | migration `0031`, `inverters_cached()`, `syncPlants()` | 10 calls/min per 2-inverter account instead of 11; new plants appear on their own |
| `readings.device_time` — the inverter's own upload timestamp | `0031`, `extractReading` | the freshness signal step 3 needs |
| `apiCalls` + `listRefreshed` per account in every poll response | `poll/index.ts` | request budget is measurable from `net._http_response` |

Verification pattern that worked: `scripts/sql/verify-0031.sql` — a single `do $$` block
that `raise exception`s on any failed criterion, run with
`supabase db query --linked -f <file>` (exit code decides). Copy that pattern.

## 3. Facts the next steps rest on (all measured, see API.md for the probes)

- **Where each stored field comes from.** Five per-inverter endpoints, no overlap:
  `input` → PV power + per-string V/I/W (strings ride free); `battery` → battery power,
  SoC, V, A, temp, kWh counters; `grid` → grid power, freq, PF, **mains voltage, relay
  status** (the outage signal); `load` → load power + counters; `output` → inverter
  output power, **voltage** (the far side of the relay), freq.
- **The minute spine** (`agg_minute`: pv, load, batt, grid, soc) needs input, battery,
  grid and load every minute. Output only matters across an open relay.
- **Per-inverter energy balance holds to ~100 W**: `load ≈ pv + grid − batt` (grid +import,
  batt +charging). So load can be derived on minutes it is not fetched.
- **Outage detection** (`q_grid_present`, alerts in `0016`–`0019`) uses 2–3 minute
  debounce windows on grid voltage/relay. Grid must stay at one minute.
- **Datalogger cadence differs per inverter.** Master `2508290475`: ~1,278 uploads/day
  (~67 s). Slave `2512082438`: **288/day, one every 5 minutes**. `device_time` only
  advances on an upload; over 10 live minutes it took 8 distinct values on the master and
  3 on the slave. Polling the slave every minute is wasted 4 times in 5.
- **The official host (`openapi.sunsynk.net`) has no `/flow` endpoint** (the web host
  does). Do not design around a one-call spine.
- **Per-inverter minute history exists on the official host** and goes back 2+ months:
  battery `soc`; grid `pac,fac`; load `pac`; input string V/I; output `pac,fac,vac1,iac1`.
  Missing: battery power/V/A/temp, grid voltage, relay, kWh counters. One call per day
  per endpoint (`date`/`edate` do not span days).
- **Storage grows ~450 MB per inverter per year**; `strings` is the largest table.

## 4. Next steps, in order

### Step 3 — freshness gate (biggest win, lowest risk now that device_time exists)

Per inverter, per minute: fetch `input` first (needed anyway). If its `pvIV[0].time`
equals the `device_time` of the inverter's previous stored row, the datalogger has not
uploaded — **skip the other four calls** and commit the previous row's values again
with the new `ts` and the same `device_time`. Otherwise fetch the four and proceed as now.

- Needs the previous row per inverter: add `p_prev` handling inside `poll_commit`
  (coalesce skipped columns from the last row for that `sn`) or fetch the previous
  device_time via a small RPC before the loop. Prefer doing it in SQL: one statement,
  no extra round trip.
- **Guard rails:** never skip on the refresh minute; never skip when the previous row
  had `grid_relay_status = '0'` or `grid_volt_v < 100` (an outage in progress); cap
  consecutive skips at 5 so a datalogger that stalls is re-read.
- Expected: slave 5 → ~1.8 calls/min. Any customer on a slow logger gets it free.
- Done criteria: over 30 live minutes, `apiCalls` averages ≤ 7.5 for this account (was
  10); `agg_minute` has no gap; the slave's stored rows change value only on minutes
  where `device_time` changed; outage alerts unchanged (`api_alerts_due()` output identical
  before/after on a quiet day).

### Step 4 — endpoint tiering on fast loggers

`load` every 5 minutes (derive `load_w` in between from the balance; carry counters
forward); `output` every 10 minutes, every minute while `grid_relay_status = '0'` or
`grid_volt_v < 100` (the burst in `poll/index.ts` already reads grid+output only).
Expected master: 5 → ~3.3 calls/min. Mark derived load minutes (a `load_source` text
column or a bit) so the integrity audit (`scripts/integrity-check.js`, DATA_PIPELINE §9)
can exclude them.

### Step 5 — use per-inverter history for `recover`

`recover` backfills logger-offline minutes from the *plant* feed, whose scaling is
unstable (DATA_PIPELINE §3.2). The per-inverter `…/day` endpoints give grid, load, SoC
directly and PV from string V×I, so the spine can be rebuilt per inverter and summed —
battery by balance. Quality change, not volume. Keep `source='plantfeed'` rows as they
are; tag new ones `source='invhistory'`.

### Step 6 — storage

Partition `readings`/`strings` by month; downsample `strings` to 5-minute rows after
90 days. Needed before the first thousand inverters, not before the first customer.

## 5. Things to leave alone

- The per-minute cadence for `input`, `battery`, `grid` on any inverter whose logger
  uploads that often. The product's premise is minute-resolution history.
- `agg_minute` first-write-wins and `readings` last-write-wins semantics in `poll_commit`.
- The 0/10/20 s shard stagger in `0030` — belt and braces, costs nothing.
- Convex or any platform move. Analysed 5 Sep 2026: the workload is SQL time-series;
  Supabase Pro is not a limit anywhere near the SunSynk ceiling.

## 6. How to work on this repo (what tripped us up)

- Production SQL: `supabase db query --linked "<one statement>"` or `-f file`. One
  statement per call; a file whose first line starts with `--` must go via `-f`.
- Local stack: `supabase start` then `supabase db reset --local` applies every migration
  (the cron section of `0009`/`0030` is a no-op locally). Multi-statement test scripts:
  `docker exec -i supabase_db_sunsynk-dashboard psql -U postgres -d postgres -v ON_ERROR_STOP=1 < file`.
- Type-check without a local Deno: from any scratch dir,
  `npx --yes deno@2 check --node-modules-dir=auto <entrypoints>`.
- Deploy order when a function needs a new RPC: `supabase db push` **then**
  `supabase functions deploy poll`. Reverse order stops the logger.
- Live check after any poll deploy: last rows of `net._http_response` (status 200,
  `results[0].apiCalls`, `listRefreshed`), `private.gaps` empty for the deploy window,
  `api_health()->>'stale' = 'false'`.
- App key/secret exist only as Supabase secrets. To probe the official API, deploy a
  throwaway gated function (pattern: `alerts-due`, `verify_jwt = false` + shared token)
  and delete it afterwards; never print or commit the key.
