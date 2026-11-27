# Rework step 3: history

SOLAR-686, part of SOLAR-678. Draft 1, 2026-11-27. Not signed.

Owners see one change: every history import shows "Fetching history" and its progress, not
only the first one (choice 1). After this step: one engine fetches every past day from the
brand, one part owns every history table, and no other part writes a history bookmark.

Facts from production (read only, 2026-11-27): database 1,221 MB. `billing.history_fetches`
0 rows, `history_lanes` 0 rows. `plant_config` 23 rows: 0 with `backfill_next` set, 22 with
`temp_next` set (the walk parks at today, it never clears).

| Table | Size |
|---|---|
| `readings` | 296 MB |
| `inverter_history` | 256 MB |
| `strings` | 220 MB |
| `agg_minute` | 177 MB |
| `inverter_history_5m` | 69 MB |
| `agg_5m` | 47 MB |
| `strings_5m`, `readings_5m` | 19 MB each |

Paths: `SF/` = `supabase/schemas/functions/`, `EF/` = `supabase/functions/`.

## Today: four ways in, two engines

| Way in | Engine | Bookmark | Shows progress | Sends "history ready" |
|---|---|---|---|---|
| New link (`plant_config_seed`, `plant_start_fill`) | `recover?plant=`, kicked every 2 min by `first_load_continue` | `plant_config.backfill_*` | Yes | Yes (`email_on_history` trigger) |
| Seat switch, restart (`write_seats` -> `request_history`) | `recover?queue=1` every minute | `billing.history_fetches` | No | No |
| Hole over 10 min (`poll_commit_batch.sql:182`) | `first_load_continue` -> `recover?plant=` | `private.refill_queue` | No | No |
| 6-hourly sweep, last 14 days | `recover` | `app_config` `RECOVER_CURSOR` | No | No |

Temperatures: today's in the `temps` job (`EF/_shared/sidejobs.ts:76`), past days in
`recover`'s walk (`plant_config.temp_next`). Plant kWh totals: `sync-plant-energy`, nightly and
on link, its own cursor. `recover` must leave plants to the queue (`recover/index.ts:605`).
Progress lives in three places; `plant_config` has three owners.

## What this part owns

New schema `history`. One part, "History", owns:

| Table | Replaces | From |
|---|---|---|
| `history.imports` | `billing.history_fetches` + `plant_config.backfill_next/until/tries` + `temp_next/tries` + `private.refill_queue` + `RECOVER_CURSOR` | Billing, Plants, Reading |
| `history.days` | the walk's position in all of the above | |
| `history.lanes` | `billing.history_lanes` | Billing |
| `agg_5m`, `readings_5m`, `strings_5m`, `inverter_history`, `inverter_history_5m`, `plant_energy` | stay where they are; owner already History | History |
| `private.rollup_progress`, `rollup_slow`, `partitions_dropped`, `history_delete_*`, `plant_purge`, `plant_wipe` | stay; owner already History | History |
| `private.recover_kicks` | dropped (no kicks) | |

The reader keeps `readings`, `strings`, `agg_minute`. History writes past minutes into
`agg_minute` through one function, `history.bank_minutes`, listed as a writer in
`owners.json` (as today's `q_insert_recovered_v2`).

`billing.plant_facts.history_purged_at` stays Billing's: it is a plan fact ("this plant's
data was deleted under the plan"), read by `plant_state`. History reports that a delete is
done in `private.history_delete_log`, as today.

**Front door.**
- Other parts call only: `history.start(plant, account, reason, pace_s)`,
  `history.stop(plant, reason)`, `history.progress(plant)` (for screens), `history.days(plant,
  from, to)` and `history.best(plant, from, to, field)` (H14).
- Reasons: `link`, `restart`, `switch`, `gap`. Pace comes from Billing
  (`request_history` keeps its repeat-fetch counter and works out `pace_s`; it stops
  writing `history_fetches`).
- Edge: one function, `history` (replaces `recover` and `sync-plant-energy`).

## Rules

Each rule has the check that proves it. The step is done when every check passes.

**One engine**

- **H1. Every past-day fetch goes through one queue and one edge function.** First import,
  seat switch, restart, hole refill, the 14-day check, past temperatures and plant kWh
  totals are all rows in `history.days`, with a kind: `minutes`, `extras` (temperatures,
  volts, Hz), `totals` (brand kWh by day and month). One open row per plant, day and kind
  (a unique index on open rows), so a gap and a first import never fetch the same day twice.
  *Check:* `recover` and `sync-plant-energy` are gone; `first_load_continue`,
  `plant_bootstrap_kick`'s recover kick, `refill_queue`, `recover_kicks`, `RECOVER_CURSOR`,
  and the cron jobs `recover`, `billing-history`, `first-load-continue`, `plant-energy` are
  gone; a test queues a first import and a gap on the same day and sees one brand call per
  inverter.
- **H2. One import per plant at a time,** not per account. A second request on a plant
  with an open import joins it (keeps the earlier start, takes the slower pace). Shared
  plants fetch once.
  *Check:* two accounts on one plant switch it in; one import, one set of brand calls.
- **H3. Newest days first** (SOLAR-171): today and the last 14 days, then back to day 60.
  60 is a setting (`app_config`), not a literal.
  *Check:* order test on the mock brand; the literal `- 60` appears 0 times in History files.
- **H4. A failed day is retried twice, then given up and noted** (as today:
  `BACKFILL_MAX_TRIES`, `history_step.sql:44`). A brand 429 backs the login off, doubling from
  60 s to 1 h (as `history_lanes` today). A night with no solar is not a failure.
  *Check:* mock brand fails a day 3 times: two retries, then `history_day_given_up`, and the
  import moves on.
- **H5. Gap recovery is the same engine.** The reader's save queues a `gap` day for a hole
  over 10 minutes (today `refill_queue`). A daily check of the last 14 days queues each day
  with missing minutes (today the 6-hourly sweep). The plant feed fallback (fills what
  inverter history could not, calibrated per day) stays, inside the brand adapter.
  *Check:* a 30-minute hole in a fixture plant is filled within 5 minutes; a day in the
  14-day window with missing minutes is queued once a night and given up when it leaves.
- **H6. Temperatures: today's stay in the `temps` job, past days are `extras` rows.** The
  `temps` job moves into History's files (it was Reading's in step 2). `temp_next` goes.
  *Check:* `temps` job code under History in `owners.json`; a new link fills 60 days of
  temperatures through `history.days`.

**Ownership and bookmarks**

- **H7. One owner per table,** in `supabase/owners.json`, checked in CI (step 2 R1). Every
  table this step adds or takes has `part: history` and only History files as writers.
  *Check:* `npm test` (owners-check) and `test:state` (db-files).
- **H8. Bookmarks are History's and nobody else writes them.** `plant_config` loses
  `backfill_next`, `backfill_until`, `backfill_tries`, `temp_next`, `temp_tries`.
  Today's other writers move to the front door:

  | Writer today | Becomes |
  |---|---|
  | `plant_config_seed` (sets the 60-day bookmarks) | `history.start(..., 'link')` |
  | `private.plant_start_fill` | `history.start(..., 'restart')` |
  | `billing.write_seats` -> `request_history` | `history.start(..., 'switch', pace_s)` |
  | `billing.purge_now`, `plant_bookmarks_clear`, `plants.purge` | `history.stop(plant, 'deleted')` |
  | `recover/index.ts` (`plant_config` update) | gone |
  | `api_overview`, `api_plant_states`, `plant_history_loading`, `history_done`, `q_missing_minutes`, `poll_jobs_v2` (reads) | `history.progress(plant)` or nothing |

  *Check:* `plant_config` has none of the five columns; `owners.json` lists no History file
  as a `plant_config` writer; `history.*` lists only History files.
- **H9. "History ready" and the progress shown come from `history.imports`.** The
  `email_on_history` trigger moves from `plant_config` to `history.imports` (status to
  `done`). Which imports show and mail: choice 1.
  *Check:* a first import on the mock brand sends one `history` mail; the screen's
  "Fetching history %" follows `history.progress`; old trigger gone.

**Brand**

- **H10. History calls only `BrandHistory`** (`EF/_shared/brands/types.ts:157`). SunSynk's
  day shapes, its feed scale (`currentFeedScale`), its web host and its paging stay in
  `EF/_shared/brands/sunsynk/`. The mock brand implements `BrandHistory` with fixed data, so
  tests and the load test run without SunSynk.
  *Check:* the contract test covers `BrandHistory` for mock and SunSynk (against
  `mock-sunsynk`); F20: "sunsynk" appears 0 times in History files; `history` imports only
  `types.ts` and the brand registry.
- **H11. Jobs carry `plant`, `brand` and `vendor_plant`** (step 2 R12). The brand's plant
  id only goes to the adapter; serials keep the R13 prefix.
  *Check:* `deno check`; the two-brand test (brand B plant "495944") imports into its own
  plant.

**Time zone**

- **H12. Every History day is the plant's local day,** from `plants.tz(plant)`. Day starts,
  "today", day 60, the 14-day window, and the daily check all use it. Calendar steps stay
  zone-free (`recover/index.ts:78`).
  *Check:* a `Europe/London` plant on a South African account: the day the clocks go back
  imports 1,500 minutes, the day they go forward 1,380; its local midnight is its day
  boundary; F20 count for `Africa/Johannesburg` in History files is 0.

**Reader comes first**

- **H13. Imports never hold up the reader.**
  - Separate edge calls and cron job from the reader; nothing in `poll` waits on History.
  - Small writes: one inverter-day per transaction (at most 1,440 minute rows), with
    `lock_timeout` 1 s and `statement_timeout` 10 s.
  - Lock order from step 2 (R19): History never locks a login row; it takes at most
    `for key share` on `plants.plants` for the version fence; never a lock held across a
    brand call.
  - Groups of 25 logins per edge call (as step 2's reader), not all logins in one isolate.
  - The reader's calls come first on a login: a login with a reader 429 in the last
    2 minutes (`plants.brand_calls`) waits; imports keep under a fleet cap of import calls a
    minute (choice 2).
  *Check:* a race test runs a poll save and an import write on one plant 100 times: no
  deadlock, save p95 within 10% of the save alone; the load proof (H17).

**Same figures**

- **H14. Day totals and best day are worked out once.** `history.days(plant, from, to)`
  gives each local day's kWh (solar, home, grid in, battery in and out), from
  `public.span_figures` and `_plant_day_energy` (step 2 R23) for days we hold and
  `plant_energy` before that.
  `history.best(plant, from, to, field)` gives the best day. Today best day is worked out
  in `public/tabs.jsx:917` and `EF/notify/index.ts:97`, day rows in both. App and mail call
  the same functions.
  *Check:* for a fixture plant and month, the app's best day and the mail's are the same
  day and value; a guardrail fails on a new `best(` in `EF/notify*` or `public/`.
- **H15. An imported day matches the live day where both exist.** The dry-run compare
  (`recover/index.ts:474`) becomes a test: an imported fixture day against the same day's
  reader rows, median error per series under a set limit.
  *Check:* the compare test on mock and on `mock-sunsynk`.

**Safe data moves**

- **H16. Each move runs: new, copy, compare to zero, switch, drop.**
  - Backup first: `pg_dump` of `public.plant_config`, `billing.history_*`,
    `private.refill_queue`, `private.recover_kicks`; and a check that the Supabase daily
    backup is from today.
  - Rehearsed on a full local copy of production, history rows included (all 1.2 GB, not
    only the small tables; step 2's first release timed out on the big ones). Tokens and
    Vault left out, emails masked; the copy is deleted after the proof.
  - No statement in the release scans or rewrites a big table under a lock. A new index on
    a history table is built `concurrently`, before the switch, outside the migration's
    transaction.
  - Switch in one transaction: copy the bookmarks (22 `temp_next` rows, 0 open fetches),
    compare (a query listing every difference, 0 rows), point callers at `history.*`, turn
    the old cron jobs off.
  - Drop one release later: the five `plant_config` columns, `billing.history_fetches`,
    `history_lanes`, `refill_queue`, `recover_kicks`. The `poll_jobs_v2` columns go only after
    step 2's follow-ups close (SOLAR-690), since it is the reader's.
  *Check:* rehearsal log: compare = 0, release time on the full copy, the reader's minutes
  during the release (0 missed); the same log from production.
- **H17. Old code goes in this step.** `recover/index.ts`, `sync-plant-energy/index.ts`,
  `billing.history_take`, `history_step`, `history_renew`, `first_load_continue`,
  `plant_history_loading`, `history_done`, `plant_bookmarks_clear`, the queue branch of
  `billing_jobs`, and their tests.
  *Check:* each name appears 0 times in `SF/`, `EF/`, `public/` and `scripts/` (except
  migrations).

**Load proof**

- **H18. 500 logins importing at once, while the reader runs, misses no reader minute.**
  Local, `load-test/v3/` with the fake SunSynk at production timings: 500 logins link at
  once and each imports 60 days; the reader runs through it.

  | Measure | Pass |
  |---|---|
  | Plant-minutes missed by the reader | 0 |
  | Reading age | as step 2 R22: on screen within 5 s of the page's ask second |
  | Reader calls answered 429 while imports run | no more than without imports |
  | Last 14 days ready, one plant alone | 5 minutes |
  | All 60 days ready, one plant alone | 30 minutes |
  | All 500 imports done | choice 2 |
  | Rows written after a plant is switched out or deleted | 0 |

  *Check:* the numbers on this page and on SOLAR-686.

## Order of work

Each step ships on its own.

1. Tests of today's behaviour on the mock brand (rows banked, order, retries, give-up), so
   the new engine is held to them. H7 owners entries, F20 known list for History files.
2. H10: `BrandHistory` contract test for mock and SunSynk; feed scale into the adapter.
3. Schema `history`, front door, edge `history` (H1-H6, H11-H13), running beside the old
   engines on the mock brand only.
4. H8, H9, H16: callers switched, bookmarks moved, old cron jobs off, in one release.
5. H14, H15: same figures; app and `notify` switched.
6. H18 load proof; rehearsal on the full production copy.
7. H17 and the drops, one release later.

## Size

Large. About 2-3 weeks. About 25 SQL functions and 6 edge files change; data to move is
tiny (22 bookmarks), the tables around it are not (1.2 GB).

## Costs

| Item | Cost a month |
|---|---|
| Engine | $0 (today's Supabase plan; one edge call per group of 25 logins a minute) |
| Load proof, rehearsal | $0 (local) |

## Needs Brynne

1. **Which imports show "Fetching history" and send the "history ready" mail?**
   - **A (recommended).** Every import shows progress. The mail goes once per plant and
     account: the first time its history is ready. A switch back or restart shows progress,
     no mail.
     *Against:* someone who switches a plant back waits with no mail saying it is done.
   - **B.** Every import shows progress and sends the mail.
     *Against:* a mail each time a plant is switched back; repeat switching means repeat mail.
   - **C.** As today: only the first import shows and mails.
     *Against:* after a switch back the page has holes with no word why.
2. **How fast may all imports run at once?**
   - **A (recommended).** A fleet cap of 600 import calls a minute, on top of one call at a
     time per login. 500 plants importing at once all finish in about 6 hours; one plant
     alone is not slowed.
     *Against:* a burst of sign-ups waits hours for older days (the last 14 days come first).
   - **B.** No fleet cap, one call at a time per login only. Fastest.
     *Against:* 500 calls at once from our address; SunSynk's limit for that is unknown and
     a block would stop the reader too.
3. Each production release stays on his say-so.

## Case against

Large, and owners see almost nothing new. The engine is rebuilt while the old one works:
the parents' plant already cannot minute-backfill (its 15-string inverter's 504), and a new
engine can break what works for the others. Moving temperatures and kWh totals into the
queue makes one engine, but a stuck queue then stops all past data at once, not one part
of it. The load proof is local against a fake; SunSynk's real limit for many logins is
not known.
