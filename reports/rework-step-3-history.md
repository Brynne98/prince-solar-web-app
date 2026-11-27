# Rework step 3: history

SOLAR-686, part of SOLAR-678. Signed by Brynne 2026-11-27: rules H1-H26; choice 1A (progress
on link, switch back and restart; mail once per plant and account); choice 2A (fleet cap on
import calls, a setting, start 600, set by the load test). Reviewed by Sol and Neon (draft 1:
both "rework"; their findings are taken below).

Owners see one change: a switch back or a restart also shows "Fetching history" and its
progress, not only a first link (choice 1). After this step: one engine fetches every past
day from the brand, one part owns every history table, and no other part writes a history
bookmark.

Facts from production (read only, 2026-11-27): database 1,221 MB. `billing.history_fetches`
0 rows, `history_lanes` 0 rows. `plant_config` 23 rows: 0 with `backfill_next` set, 22 with
`temp_next` set (that walk parks at today, it never clears).

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

## Today: five ways in, two engines

| Way in | Runs in | Bookmark | Shows progress | "History ready" mail |
|---|---|---|---|---|
| New link (`plant_config_seed`, `plant_start_fill`) | `recover?plant=`, kicked every 2 min by `first_load_continue` | `plant_config.backfill_*`, `temp_next` | Yes | Yes (`email_on_history`, `plant_listed`) |
| Seat switch, paid restart (`write_seats`, `apply_purchase:43` -> `request_history`) | `recover?queue=1` every minute | `billing.history_fetches` | No | No |
| Hole over 10 min (`poll_commit_batch.sql:182`, `poll_commit.sql:70`) | `first_load_continue` -> `recover?plant=` | `private.refill_queue` | No | No |
| 6-hourly run, last 14 days, then past temperatures | `recover` | `RECOVER_CURSOR`, `temp_next` | No | No |
| Plant kWh totals, nightly, on link, and on a mail's resync (`notify:230`) | `sync-plant-energy` | `SYNC_CURSOR` | No | No |

Today's temperatures (output/day) run in the `temps` job (`EF/_shared/sidejobs.ts:78`);
today's grid Hz and the 31-day trim of `inverter_history` (`q_prune_inverter_history`,
`recover/index.ts:233`) run only in `recover`. `recover` leaves plants to the queue
(`recover/index.ts:589-591`).

## What this part owns

New schema `history`. One part, "History", owns:

| Table | Replaces | From |
|---|---|---|
| `history.imports` (one per plant while open) | `billing.history_fetches`, `plant_config.backfill_*`, `temp_next`, `temp_tries` | Billing, Plants |
| `history.import_accounts` (who asked, at what pace) | `history_fetches.account`, `fetch_no`, `target_s` | Billing |
| `history.days` (plant, day, kind, status, tries, due) | the walk position in all of the above, `private.refill_queue` | Reading |
| `history.lanes` (per login: one step at a time, backoff) | `billing.history_lanes` | Billing |
| `history.runs` (per task: last run, cursor) | `RECOVER_CURSOR`, `SYNC_CURSOR`, `private.recover_kicks` | |
| `agg_5m`, `readings_5m`, `strings_5m`, `inverter_history`, `inverter_history_5m`, `plant_energy` | stay where they are; owner already History | |
| `private.rollup_*`, `partitions_dropped`, `history_delete_*`, `plant_purge`, `plant_wipe` | stay; owner already History | |

The big tables are not moved to the new schema: a move touches every function that names
them and buys nothing `owners.json` does not already give.

The reader keeps `readings`, `strings`, `agg_minute`. History writes past minutes into
`agg_minute` through one function, `history.bank_minutes` (today `q_insert_recovered_v2`),
listed as its writer in `owners.json`.

`billing.plant_facts.history_purged_at` stays Billing's: it is a plan fact read by
`plant_state`. History reports a finished delete in `private.history_delete_log`, as today.

**Front door.**
- Billing and Plants call only: `history.start(plant, account, reason, pace_s)`,
  `history.leave(plant, account)`, `history.stop(plant, 'deleted')`.
- Screens call `history.progress(plant)` through `api_overview` and `api_plant_states`.
- Reasons: `link`, `restart`, `switch`, `gap`, `check`. Billing works out `pace_s`
  (H4) and keeps its repeat-switch counter (`account_events` kind `history_fetch`).
- Edge: one function, `history`, with tasks `queue`, `check`, `totals`, `trim` (replaces
  `recover` and `sync-plant-energy`).

## Rules

Each rule has the check that proves it. The step is done when every check passes.

**One engine**

- **H1. Every past-day fetch of minutes and temperatures goes through `history.days`.**
  Kinds: `minutes` (the minute spine and, free with it, the inverter extras) and `extras`
  (temperatures, volts, Hz, for a day whose minutes are not needed). One open row per plant,
  day and kind (unique index on open rows), so a gap and a first import never fetch a day
  twice.
  *Check:* a test queues a first import and a gap on the same day: one brand call set per
  inverter; `recover`, `sync-plant-energy`, `first_load_continue`, the recover kick in
  `plant_bootstrap_kick`, `refill_queue`, `recover_kicks` and both cursors are gone.
- **H2. Plant kWh totals are a task of the same edge function, not day rows.** Months and
  years do not fit day rows. `totals` keeps today's reach: nightly this year and the last
  2 months; on link, restart and Sundays (plant's time) every year back to commissioning
  and 6 months of days; grid scale from `q_grid_feed_scale`, written with 1 on a failed
  lookup (SOLAR-522). It takes its brand calls from the same per-login lanes and budget
  (H9). `notify`'s resync (`notify:230`) calls `history.start(..., 'totals')`.
  *Check:* `grid_test.ts` passes on the new task; a test plant links and gets monthly rows
  back to its first year; a nightly run makes 3 calls per plant.
- **H3. One import per plant; accounts are tracked on it.** A second account asking joins
  the open import (`history.import_accounts`). `history.leave` removes one account; the
  import stops only when no account holding the plant is left. The pace is the fastest of
  the accounts still on it, so a repeat switcher never slows a co-owner. The login used is
  chosen at each step from Billing's route (`billing.fetch_lane`), so an account leaving
  moves the import to a login that still reads the plant, with its days kept.
  *Check:* two accounts on one plant: both switch in, one import and one set of calls; A
  switches out, B's import goes on at B's pace through B's login; B switches out, the
  import stops.
- **H4. Today's pacing is kept as is** (`request_history.sql:12-26`, `history_step.sql:55-66`):
  switches counted over 7 days; the first 3 at full speed; the 4th spread over 20 minutes,
  doubling each time to 24 hours; days spread evenly over that time; a slowed import frees
  its login between days for other accounts; on the share login the account whose last
  import started longest ago goes first (`history_take.sql:31-33`). A paid restart imports
  again for the seats it keeps (`apply_purchase.sql:43`), from yesterday back.
  *Check:* today's billing checks on pacing pass against the new tables; a 5th switch in a
  week takes 40 minutes for 60 days; two accounts on the share login alternate.
- **H5. Newest days first** (SOLAR-171): today and the last 14 days, then back to day 60.
  60 is a setting (`app_config`), not a literal.
  *Check:* order test; the literal `- 60` appears 0 times in History files.

**The queue: claims, retries, gates**

- **H6. Every step is claimed, and a lost claim writes nothing.** A step is handed out with
  a claim id for 90 s, renewed every 30 s by the worker (as `history_renew` today). Each
  write passes the claim id; a write with an old claim is refused in the database. A worker
  killed mid-day leaves the day open; the next run takes it after the claim runs out.
  *Check:* tests: a killed worker's day is taken again after 90 s; a worker whose claim was
  taken over writes 0 rows.
- **H7. Retries and waits keep today's meaning.** A failed day is retried twice, a minute
  apart, then given up and noted (`history_day_given_up`), and the import moves on. A brand
  429 backs the login off, doubling from 60 s to 1 h, and does not use a retry. A night with
  no solar is not a failure. A plant with no inverter serials yet waits without using a
  retry (`recover/index.ts:352`). A worker out of time hands the day back unspent.
  *Check:* one test per sentence, on `mock-sunsynk`.
- **H8. Billing gates every import at three points: queue, hand-out, write.**
  - Queue: `history.start` queues nothing for a paused plant or one not read now (today
    `plant_config_seed.sql:20` and `plant_start_fill.sql:25-28`).
  - Hand-out: a day is handed out only while `billing.reads_plant` holds for an account on
    the import and its login is `ok` (`history_take.sql:19-21`); a plant over the seat count
    or past its trial waits in the queue with its days kept.
  - Write: every write runs, in one transaction, the claim check (H6), the plant version
    fence, `billing.guard_write`, and the delete fence (`private.history_deleting`). Lock
    order: the plant row first (`for share`, as `billing.write_allowed`), then the queue row.
  *Check:* tests for a paused plant, an ended trial, an over-seat account, a shared plant
  one account can still read; and switch-out, delete, and switch straight back while a
  worker is paused mid-day, for minutes, extras and totals: 0 rows written after the
  switch-out or delete.
- **H9. Brand calls stay inside a budget counted in the database.**
  - Per login: one step at a time (`history.lanes`), as today.
  - The reader comes first on a login: the brand adapter records a 429 per login with a time
    (new, in Plants' adapter code; `plants.brand_calls` has no login key today), and History
    gives that login no step for 2 minutes. 403 quota answers count as 429.
  - Fleet: History hands out at most N calls a minute in all (choice 2), counted by the
    calls a step will make (inverters x calls per inverter-day, both host paths), in
    `history.take`, not in an isolate's memory. The SunSynk web host path (`api.ts:404-429`)
    goes through the same backoff and count.
  - Hand-out is split by lane hash (`take(shard, shards)`), groups of 25 logins per edge
    call; no single lock makes 19 of 20 groups come back empty.
  *Check:* a test where the reader gets a 429 on login X: X gets no import step for 2
  minutes; with N = 60, a minute hands out at most 60 calls across 4 parallel groups.
- **H10. Finished work is cleared and a stuck queue alerts.** Closed `history.days` rows go
  after 7 days, closed imports after 30. `job-check` alerts when an open day has been due
  for over 30 minutes, and on the `history` heartbeat that `billing.alerts` watches today
  (`alerts.sql:53`; the beat moves with the queue).
  *Check:* a stuck-queue test raises the alert; the heartbeat still beats.

**Gaps, temperatures, trim**

- **H11. Gap recovery is the same queue, and keeps today's care.**
  - The reader's save queues `gap` rows for each local day a hole over 10 minutes touches
    (a hole can cross midnight).
  - The 6-hourly check of the last 14 days stays 6-hourly; it queues each day with missing
    minutes, checking `agg_5m` for days past 31 (after `agg_minute_rollup`).
  - The last 10 minutes are left to the reader. A complete row is never overwritten; a
    `poller_partial` row is replaced (`q_insert_recovered.sql:18-21`).
  - The plant feed fills what inverter history could not, calibrated against that day's
    own reader rows, thin days borrowing today's scale (`recover/index.ts:289-331`). The
    feed calls stay in the adapter; History passes our buckets in, so the adapter makes no
    database calls.
  - A day that leaves the 14-day window with minutes missing is given up and noted
    (SOLAR-525).
  - Gap rows do not show "Fetching history".
  *Check:* tests: a hole from 23:50 to 00:20 fills both days; a forced feed fallback on a
  thin day; a complete row kept; a partial row replaced; the live edge untouched.
- **H12. Temperatures: today's in the `temps` job, past days as `extras` rows.** `temps`
  moves to History's files and also banks today's grid Hz (today only in `recover`,
  `recover/index.ts:176`). A day where one of the two endpoints fails keeps what the other
  gave and retries the failed one only.
  *Check:* a new link fills 60 days of temperatures through `history.days`; today's grid Hz
  rows appear without `recover`; partial-failure test.
- **H13. The 31-day trim of inverter history runs on its own,** daily per plant, as the
  `trim` task (`q_prune_inverter_history`: roll up to `inverter_history_5m`, then delete).
  *Check:* `inverter_history` on the rehearsal copy holds no row older than 31 days after
  one run; `inverter_history_5m` gains the rolled-up days.

**Ownership, bookmarks, screens**

- **H14. One owner per table,** in `supabase/owners.json`, checked in CI (step 2 R1). Every
  table in "What this part owns" has `part: history` and only History files as writers,
  except `agg_minute` (Reading's, with `history.bank_minutes` listed).
  *Check:* `npm test` (owners-check) and `test:state` (db-files); a new History write from a
  Billing file fails.
- **H15. Bookmarks are History's and nobody else writes them.** `plant_config` loses
  `backfill_next`, `backfill_until`, `backfill_tries`, `temp_next`, `temp_tries`.

  | Writer or reader today | Becomes |
  |---|---|
  | `plant_config_seed` (60-day bookmarks) | `history.start(..., 'link')` |
  | `private.plant_start_fill` | `history.start(..., 'restart')` |
  | `billing.write_seats`, `apply_purchase` -> `request_history` | `history.start(..., 'switch' / 'restart', pace_s)`, `history.leave` |
  | `billing.purge_now`, `plant_bookmarks_clear`, `plants.purge` | `history.stop(plant, 'deleted')` |
  | `recover/index.ts` | gone |
  | `api_overview`, `api_plant_states`, `plant_history_loading`, `history_done`, `plant_listed`, `q_missing_minutes`, `poll_jobs_v2` | `history.progress(plant)`, or nothing |

  *Check:* `plant_config` has none of the five columns; no History file writes
  `plant_config`.
- **H16. Screens read one progress shape.** `history.progress(plant)` gives:
  `fetching` (bool), `percent`, `minutesFrom` (oldest day still to come, today's
  `backfillNext`), `extrasFrom` (today's `tempNext`). `public/data.jsx:346,566-595` and
  `public/chart.jsx:476-479,840-844` read it; "more every six hours" changes to what the
  queue does.
  *Check:* screenshots at phone and desktop width, light and dark, during and after an
  import on the mock plant; the old `sync.*` names gone from `public/`.
- **H17. "History ready" comes from `history.imports`.** The mail goes when an import is
  done (given-up days count as done; the day is noted). A second account listing a plant
  whose history is already ready gets its one mail (today `plant_listed.sql:14`). Mail held
  until the kWh totals are in, as today (`notify:210-223`). Which imports mail: choice 1.
  *Check:* a first import sends one mail; a late sharer gets one; a switch back sends per
  choice 1; old trigger gone.

**Brand and time zone**

- **H18. History calls only `BrandHistory`** (`EF/_shared/brands/types.ts:157`). SunSynk's
  day shapes, feed scale, web host and paging stay in `EF/_shared/brands/sunsynk/`. The
  `mock` brand today wraps the SunSynk adapter over `mock-sunsynk` (`brands/index.ts:35`);
  tests and the load test run on it with fixed fixture days.
  *Check:* the contract test covers `BrandHistory` on `mock-sunsynk`; F20: "sunsynk" 0 times
  in History files; `history` imports only `types.ts` and the brand registry.
- **H19. Jobs carry `plant`, `brand` and `vendor_plant`** (step 2 R12); serials keep the R13
  prefix.
  *Check:* `deno check`; the two-brand test (brand B plant "495944", same serial) imports
  into its own plant, its own `inverter_history` rows.
- **H20. Every History day is the plant's local day,** from `plants.tz(plant)`, whatever its
  length. Fixed today: `dayStartEpoch` takes the offset at noon, an hour off on a day the
  clocks change (`EF/_shared/localtime.ts:10-20`); `1440` in `invhistory.ts:263,286`;
  `+ 86400` in `q_missing_minutes.sql:16` and `q_missing_minutes_day.sql:9`. Calendar steps
  stay zone-free.
  *Check:* a `Europe/London` plant: the day the clocks go back banks 1,500 minutes, the day
  they go forward 1,380, through the real bank path; F20 count for `Africa/Johannesburg` in
  History files is 0.

**Reader comes first**

- **H21. Imports never hold up the reader.** Separate edge calls and cron job; nothing in
  `poll` waits on History. One inverter-day per transaction (at most 1,500 rows) with
  `lock_timeout` 1 s and `statement_timeout` 10 s. History never locks a login row and never
  holds a lock across a brand call.
  *Check:* a race test runs a poll save and an import write on one plant 100 times: no
  deadlock, no save waits over 1 s; a test write held past `lock_timeout` gives up and its
  day is retried.

**Same figures**

- **H22. An imported day matches the live day where both exist.** The dry-run compare
  (`recover/index.ts:474`) becomes a test: an imported fixture day against the same day's
  reader rows, with at least 600 minutes of overlap, median and p90 error per series under
  set limits.
  *Check:* the compare test on `mock-sunsynk`.

Best day (`tabs.jsx:917`, `notify:97`) is not in this step: `_plant_day_energy` and
`span_figures` already give day and span totals; best day moves with mail in step 4
(SOLAR-682).

**Safe data moves**

- **H23. Each move runs: new, copy, compare to zero, switch, drop.**
  - Backup first: `pg_dump` of `public.plant_config`, `billing.history_*`,
    `private.refill_queue`, `private.recover_kicks`, `app_config`; and the Supabase daily
    backup from today.
  - Rehearsed on a full local copy of production, history rows included (all 1.2 GB; step
    2's first release timed out on the big tables). Tokens and Vault left out, emails
    masked, the copy deleted after the proof. The reader runs against the copy during the
    release.
  - No statement in the release scans or rewrites a big table under a lock. New indexes on
    history tables are built `concurrently`, before the switch.
  - Fence first: the old cron jobs (`recover`, `billing-history`, `first-load-continue`,
    `plant-energy`) are unscheduled by name, and the release waits until no `recover` call
    is still running (`recover_kicks` with no `net._http_response`).
  - Switch in one transaction: copy every open bookmark, retry count, queued gap and login
    backoff (whatever production holds that minute, not only today's counts), compare (a
    query listing every difference, 0 rows), point callers at `history.*`, schedule the new
    jobs.
  - A way back, tested on the copy with writes running: the old jobs and callers switched
    back, bookmarks copied back.
  - Drop one release later: the five `plant_config` columns, `billing.history_fetches`,
    `history_lanes`, `refill_queue`, `recover_kicks`. The `poll_jobs_v2` bookmark columns go
    only after step 2's follow-ups close (SOLAR-690); it is the reader's.
  *Check:* rehearsal log: compare = 0, release time on the full copy, reader minutes during
  the release (0 missed), the way back run once; the same log from production.
- **H24. Old code goes in this step.** `recover/index.ts`, `sync-plant-energy/index.ts`,
  `billing.history_take`, `history_step`, `history_renew`, `request_history`'s fetch rows,
  `first_load_continue`, `plant_history_loading`, `history_done`, `plant_bookmarks_clear`,
  the queue branch of `billing_jobs`, and their tests.
  *Check:* each name appears 0 times in `SF/`, `EF/`, `public/` and `scripts/` (migrations
  aside).

**Security**

- **H25. The browser cannot reach `history.*`.** No grants to `anon` or `authenticated` on
  the schema; `start`, `leave`, `stop`, `bank_minutes` run as definer and are granted to
  `service_role` only. `history.progress` is read only through `api_*` functions that
  check `my_plant_ids`.
  *Check:* a select and each call as `authenticated` and `anon` return 42501; user A's
  `api_overview` shows no progress for user B's plant.

**Load proof**

- **H26. 500 logins importing at once, with the reader running, miss no reader minute.**
  Local, `load-test/v3/`, fake SunSynk at production timings with per-login and fleet 429s,
  before the production release. 500 logins link at once and each imports 60 days, with
  side jobs, the share login, switches and deletes mid-run, and steady gap traffic.

  | Measure | Pass |
  |---|---|
  | Plant-minutes with no reader row (`source = 'poller'`), counted apart from imported ones | 0 |
  | Reading age | as step 2 R22: on screen within 5 s of the page's ask second |
  | Reader calls answered 429 | no more than in the same run without imports |
  | Rows written after a switch-out or delete | 0 |
  | Old days still moving while gaps run | yes |
  | Last 14 days ready, one plant alone | 5 minutes |
  | All 60 days ready, one plant alone | 30 minutes |
  | All 500 imports done | measured; signed with choice 2 |

  *Check:* the numbers on this page and on SOLAR-686.

## Order of work

Each step ships on its own.

1. Tests of today's behaviour on `mock-sunsynk` (rows banked, order, pacing, claims,
   retries, give-ups, gates, feed fallback, trim), so the new engine is held to them. H14
   owners entries, F20 known list for History files.
2. H20 time zone fixes in today's code (small, ships first).
3. Schema `history`, front door, edge `history` (H1-H13, H18-H21, H25), beside the old
   engines, on the mock brand only.
4. H26 load proof, H23 rehearsal on the full production copy.
5. H15-H17, H23: callers and screens switched, bookmarks moved, old jobs off, in one
   release.
6. H24 and the drops, one release later.

## Size

Large. About 3 weeks. About 30 SQL functions, 7 edge files and 2 screen files change. Data to
move is tiny (22 bookmarks); the tables around it are not (1.2 GB).

## Costs

| Item | Cost a month |
|---|---|
| Engine | $0 (today's Supabase plan; one edge call per group of 25 logins a minute) |
| Load proof, rehearsal | $0 (local) |

## Needs Brynne

Signed 2026-11-27: H1-H26, choice 1A, choice 2A. The options as signed:


1. **Which imports show "Fetching history" and send the "history ready" mail?**
   - **A (recommended; Sol and Neon agree).** A link, switch back or restart shows progress.
     The mail goes once per plant and account: the first time its history is ready. Gap
     refills show nothing.
     *Against:* someone who switches a plant back waits with no mail saying it is done.
   - **B.** Same, and every import sends the mail.
     *Against:* a mail each time a plant is switched back.
   - **C.** As today: only a first link shows and mails.
     *Against:* after a switch back the page has holes with no word why.
2. **How fast may all imports run at once?**
   - **A (recommended; Sol and Neon agree).** A fleet cap on import calls a minute, a
     setting, on top of one step at a time per login. Start at 600; the load test sets the
     number and the time for 500 plants (estimated 6 hours or more with multi-inverter
     plants). One plant alone is not slowed.
     *Against:* a burst of sign-ups waits hours for older days (the last 14 days come first);
     600 is a guess until measured.
   - **B.** No fleet cap, one step at a time per login only. Fastest.
     *Against:* hundreds of calls at once from our address; SunSynk's limit for that is not
     known and a block would stop the reader too.
3. Each production release stays on his say-so.

## Where reviewers disagree

| Point | View | Taken |
|---|---|---|
| kWh totals in the day queue | Neon: months and years do not fit day rows; keep a separate task | Separate task, same budget (H2) |
| Best day in this step | Sol and Neon: cut, it is not the engine | Cut; step 4 |
| Gap check cadence | Sol: once a day is a change from 6-hourly | Stays 6-hourly |

## Case against

Large, and owners see little new. The engine is rebuilt while the old one works: the
parents' plant already cannot minute-backfill (its 15-string inverter's 504), and a new engine
can break what works for the others. Holding today's pacing, claims and gates exactly makes
the new queue nearly as detailed as the old one; the gain is one place, not less logic. The
load proof is local against a fake; SunSynk's real limit for many logins is not known.
