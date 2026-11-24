# SOLAR-656: Poller v3, steady per-second reading for 10,000 logins (design v3.1, 2026-11-24)

Design only. No code or prod change until Brynne says yes. Follows SOLAR-650 (design v2 in
`reports/scale-solar-650-poll-waves.md`; its Part B was live 16:23-19:27 UTC today and is
being removed). v3.0 went to the council (Neon, Sol, Astra, Fable): all four said "go with
changes". v3.1 takes their changes, checked against the code; see "Council" at the end.

## Target and stages

10,000 logins / 20,000 inverters is the design target (~10x a good 1-2 year outcome). Built in
stages. Each stage runs the same per-second reading loop; only the host changes. Each stage's
way back is the stage before it.

| | Today | Stage 1: Supabase only | Stage 2: worker |
|---|---|---|---|
| Logins | ~15 | up to the switch point (expected 2,000-4,000, measured) | to 10,000+ |
| Reader | edge shard per 10 logins, all at :00 | a few long edge "lanes", each reading its seconds all minute | one always-on program + a standby |
| Saves | 1 PostgREST call per login | 1 direct-Postgres batch per lane per second | 1 batch per second |
| Way back | none | today's poller (flag) | stage 1 lanes (flag) |

| Load | 3,000 logins | 10,000 logins |
|---|---|---|
| SunSynk calls / min (~4.5 per inverter) | ~27,000 (~450/s) | ~90,000 (~1,500/s) |
| Rows / min (readings + strings + agg) | ~30,000 | ~100,000 |

## What breaks today (checked)

1. All shards are posted at :00 through pg_net (0181:159, 0030:163-180, 10 logins a shard).
   pg_net 0.20.4 sends in batches of 200 and waits for each batch: head-of-line blocking.
2. Each login saves through its own PostgREST calls (`inverters_cached`, `poll_commit_v2`,
   `account_mark`, token writes, temps idx:194-201, detection idx:532-556, plant sync
   ss:590-695). Pool timeouts at 1,000 logins locally; prod PostgREST has ~16 connections and
   the web app shares it.
3. Every shard works out `billing.reading_routes` for the whole fleet (0246:99-175) with
   `billing.account_status` per account.
4. `sunsynk_tally` deadlocks: shards upsert the same rows in varying order (0178:24-40).
5. No fleet-wide cap on SunSynk calls in flight; `MAX_IN_FLIGHT = 10` is per login (ss:347).
6. No rule for late work: old way stores late (slow test: 123 s median); Part B refused it
   (11,740 lost).

(idx = `functions/poll/index.ts`, ss = `functions/_shared/sunsynk.ts`, numbers = migrations.)

## Design

### 1. Read seconds
- A login's second = hash of its id mod 60, as `tempMinute` does today (idx:192). No column,
  no rebalancing job.
- The share login (and any login over 10 inverters) is split: each plant gets its own second
  from a hash of the plant id. The share login reads every claimed plant (ss:88-90,
  0246:116-119); one second for it would be ~200 plants at 10 in flight. Its refresh token does
  not rotate (ss:18), so two lanes renewing it at once is harmless.
- At 10,000: ~170 logins and ~1,500 calls a second, flat.

### 2. The reading loop (same code on both hosts)
- Step 0 of the work: move `fetchInverter`, `readingRow`, `pollAccount` and helpers out of
  `poll/index.ts` (unexported today, idx:295-372) into `_shared`, and give `_shared/sunsynk.ts`
  a database handle that can be PostgREST or direct Postgres (`db` is PostgREST only,
  ss:47-50). No behaviour change; ships on today's poller first.
- Each second the loop starts the reads due that second. A read has a hard deadline of 50 s
  from its second (today a call can take ~50 s with retries, ss:152, ss:382-386); past it, the
  read is dropped and the minute counted lost (recover refills it).
- A read that cannot start within 20 s of its second is skipped and counted lost.
- Fleet-wide cap on calls in flight, sized from calls/s x p99 latency (Little's law), not a
  fixed 600. Back off per login on 429 (rate limit is per login, memory 2026-11-10); the fleet
  cap shrinks only on fleet-wide signals (timeouts, 5xx, network).

### 3. Billing: full list every 10 s, ends carried with the route
- Every 10 s the loop loads the **full** set of routes for its seconds (one set-based query, as
  0253:151-156 did), not a change feed: billing tables have no change stamp (0240), and a free
  week, plan end, pay-by date or a seat's future `closed_at` end by the clock with no row
  written (0241:100-132, 0246:104).
- Each route carries `ends_at` (the earliest of those times). The loop stops a read the second
  it passes `ends_at`, without waiting for the next list.
- Each read keeps the plant version it **started** on and sends that at save (0246:180-200).
- A plant the save refuses is dropped from the loop at once.
- `reading_routes` becomes set-based (no `account_status` loop per account).

### 4. Batch save
- `poll_commit_batch(p_rows)`: many logins in one transaction over a direct connection, with
  every rule of today's save (0250:36-120 and 0246:219-256):
  - readings and strings: replace the row for that minute, keep a concurrent insert's winner
    (0250:41-42, 0250:66-67); keys deduped in staging first.
  - unused-string drop, `used_strings`, `string_slots` (0250:52-65).
  - agg first write wins; `poller_partial` kept (0250:97).
  - gaps over 90 s logged; over 600 s queued for refill (0250:83-92). Keeps the indexed
    `max(ts)` lookup, set-based. No new last-minute table (it would need every agg writer,
    recover included, to keep it right).
  - newer token wins, and saved even when every plant is refused (0250:105-109, 0246:240);
    other logins on the plant get `last_ok_at` (0250:110-114); `billing.guarded` set
    (0246:242); `history_purged_at` cleared (0246:249-252).
  - set-based `write_allowed`, with lock order **logins then plants**, the same as
    `account_mark` (0246:347-365). Today's save locks plants then logins: a deadlock risk
    that grows with batch size.
- Each batch holds one minute only. `email_poll_step` takes one `p_ts` (0231:27), so it runs
  per minute per batch.
- On deadlock: retry once. On any other error: split and save login by login, so one bad row
  costs one login, not 170.
- Temps, detection and plant sync (~5,000 calls a minute at 10,000) go through the same
  direct connection, batched where the function allows.
- `sunsynk_tally` and `poll_run_log`: summed in memory, written once a minute, rows sorted by
  key. Removes the deadlock.

### 5. Stage 1 host: edge lanes
- Supabase edge limits (docs, checked 2026-11-24): 2 s CPU per request (async I/O not counted),
  400 s wall clock on paid plans, 256 MB memory, background work through
  `EdgeRuntime.waitUntil`.
- The minute cron posts **K lanes** (one pg_net batch, K well under 200). A lane answers at
  once and reads its share of the 60 seconds in the background, so pg_net never waits on it.
  K = calls per minute / calls one lane can do in 2 s CPU, measured.
- Each lane loads its routes and cached inverters in one query, then saves once a second over
  one pooled direct connection (Supavisor transaction mode).
- Shard-0 chores move to their own cron jobs: `retryShareLogin` (idx:681), the PostHog call
  report (idx:601-605), `poll_runs` pruning (0251:52-54). `job-check` counts lane runs, not
  `poll:s*` (0234:61-65).

### 6. Stage 2 host: worker
- Same loop as a long-running Deno program. One active copy and one standby (not half the
  seconds each).
- The active copy holds a lease with a **number issued by the database**; every batch save
  checks it. A paused copy that wakes after a takeover cannot write.
- Heartbeat = time of the last successful save, not lease renewal.
- On takeover: load routes and `inverters_cached` (last reading, carry run, upload interval,
  0230:24-28) before the first read.
- Memory between minutes (last reading per inverter) saves one query per login per minute.

### 7. Ways back
- `private.poll_mode` gets new values (`lanes`, `worker`) beside today's (0253:56-60). The
  cron SQL for each path is plain and calls nothing new.
- Stage 1: `edge` = today's poller. It carries ~1,000 logins at most, so automatic fallback
  only applies under a login count; above it, fallback is by hand.
- Stage 2: fallback = stage 1 lanes. Automatic when the last save is older than 120 s, checked
  every 30 s; latched until a person switches back after the old path has drained.
- Overlap is not free: calls double for that minute, and a paused path can log false gaps. The
  fence (6) and the latch keep it to one switch.

### 8. Pages ask after their reading lands (Part C)
- The live answer returns the plant's read second. The page asks at
  `read second + measured p95 landing + 0-4 s from the plant id`. Today's formula stays as the
  fallback. Devices on one plant still ask together (SOLAR-70); midnight re-ask stays
  (SOLAR-648).

## Switch point: when stage 1 moves to the worker

Measured from the run log every day. Move when any of these holds for 3 days running:
1. Lanes needed above 30 (pg_net batch and edge concurrency headroom).
2. Any lane above 60% of its 2 s CPU, or any edge shutdown for CPU or memory.
3. p95 second-to-save above 25 s.
4. Plant-minutes lost not caused by SunSynk above 0.1%.

Expected at 2,000-4,000 logins; the load test gives the first number (CPU per SunSynk call x
calls per lane).

## Sizing (estimates; the load test checks them)

Measured in prod today: readings ~230 bytes a row and strings ~80 bytes a row, indexes included
(254 MB and 177 MB for ~37,900 readings and ~73,200 strings a day, 31 days).

| | 3,000 logins | 10,000 logins |
|---|---|---|
| Minute tables, 31 days | ~105 GB | ~350 GB (+ 5-minute history, forever) |
| Postgres compute | Medium or Large | XL (16 GB RAM): one day of hot rows is ~11 GB |
| Reader | stage 1: K edge lanes | 2 x 4 vCPU workers (Deno runs one thread; ~1,500 HTTPS/s) |
| Calls in flight | ~450 slow mix | ~1,500 slow mix (5% at 10-20 s) |

Retention is a separate decision: 14 days of minute rows at 10,000 is ~160 GB.

## Load test (local)

Same harness as SOLAR-650 (own `supabase start` on 5632x, fake SunSynk node server with
latency/slow/429/503 knobs, fleet SQL as `pg_temp.fleet`). Never the shared stack on 5532x.
Local edge does not enforce the 2 s CPU limit, so CPU per call is measured and K worked out.

- Fleets: 500 and 1,000 logins (old way still works: the fair comparison) and 3,000 logins /
  6,000 inverters (2,700 x 1 plant x 2 inv; 270 x 1 x 1; 25 x 3 plants x 6 inv; 5 x 6 plants x
  36 inv) plus one share login with 500 plants.
- Runs (stage 1 lanes; worker where marked):
  1. Normal, 150-450 ms per call, 2-hour soak (covers hourly plant sync and temps).
  2. Slow: 5% of calls 10-20 s, 5% 429.
  3. SunSynk outage: all 503 for 2 minutes.
  4. Billing ends: 50 seats closed, 20 logins needs_reconnect, 20 free weeks ending **by the
     clock with no row written**. Count rows written after (must be 0) and reads started after
     (must be 0 after `ends_at`).
  5. Database stalled 30 s.
  6. Poison row in a batch.
  7. Worker paused, standby takes over, paused copy resumes (worker).
  8. Fallback to the previous stage and back.
- Measured: plant-minutes lost, second-to-save median and p95, share stored before the page
  asks, peak DB connections, CPU per call, lane CPU, memory, errors by kind.
- Pass: run 1 loses 0; run 2 under 0.5% with p95 under 25 s; run 4 writes 0; run 6 loses one
  login only; run 7 writes nothing from the paused copy.

## Order of work

0. SunSynk asked the request rate allowed per app key (every call signs with one key, ss:37,
   ss:142). Asked by Brynne; answer pending (2026-11-24).
1. Move the reading code to `_shared`, database handle injectable. Ships on today's poller.
2. Database half: `poll_commit_batch`, set-based routes with `ends_at`, sorted tally, mode
   values, chores to own cron jobs. Today's poller keeps working.
3. Stage 1 lanes, load test, numbers into this file.
4. Stage 1 in prod in shadow (reads, writes nothing) for a day, then switch.
5. Part C page change.
6. Stage 2 worker when the switch point says so.

## Council (2026-11-24)

All four: go with changes. Taken: full route list not changes (all four), carry `ends_at`
(Neon, Fable, Astra), version from the read's start (Fable), every 0250 save rule (all four),
lock order and split-on-error (Fable, Neon), one active + standby with a fenced lease (all
four), cap sized from the fleet and per-login backoff (all four), hash seconds (Fable), share
login split (Neon, Fable), shard-0 chores moved (Neon), more test runs (all four).

Not taken, or corrected:
- Fable: "the app key already hit quota 504s at ~130 calls/min". Those 504s (2026-09-12) were
  Supabase's gateway on edge-to-PostgREST calls on the Free plan, not SunSynk. The app key's
  rate is still unknown, so step 0 stays.
- Neon: 850 GB-1 TB of minute tables. Prod's measured row sizes give ~350 GB at 31 days.
  Astra/Sol's 45 bytes a row was a check on my old 200 GB; both were right that it was low.
- Neon: a new `plant_last_minute` table. Dropped; keeps `max(ts)` (Astra, Sol, Fable).
- v3.0 said "overlap is safe". Wrong: calls double and gaps can be false. Fence + latch.
- v3.0 cited idx:330-379 for the call count; the right lines are idx:295-372.

## Strongest case against

Stage 1 still leans on edge limits we cannot raise (2 s CPU, 256 MB); if CPU per call is high,
the switch point comes early and stage 1 was a detour. The case for it: no new host while
there are few users, and it becomes stage 2's way back.
