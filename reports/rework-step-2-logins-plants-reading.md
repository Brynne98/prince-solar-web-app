# Rework step 2: logins, plants and reading

SOLAR-681, part of SOLAR-678. Draft 2026-11-26, not signed.

Owners see nothing new, apart from one fix: a plant's own time zone is used for its day.
After this step: one home for logins, one home for each login's plant list, our own plant
id, SunSynk behind a brand interface, and a reader that only reads.

Facts from production (read only, 2026-11-26): 26 rows in `private.sunsynk_accounts`, 25 in
`billing.logins`; 33 in `plant_users`, 33 in `billing.login_plants`; 23 plants, all brand
`sunsynk`, every one with `id = external_id`, ids 495944..900006022. `plant_config.timezone`
already exists (4 zones in use). `billing.markets.default_time_zone` already exists. `pgmq`
1.5.1 is available, not installed.

Paths: `SF/` = `supabase/schemas/functions/`, `EF/` = `supabase/functions/`.

## What this part owns

New schema `plants`. One part, "Logins and plants", owns:

| Table | Replaces | From |
|---|---|---|
| `plants.logins` | `private.sunsynk_accounts` + `billing.logins` | Data logins, Billing |
| `plants.login_plants` | `public.plant_users` + `billing.login_plants` | Plants, Billing |
| `plants.claims` | `billing.plant_claims` | Billing |
| `plants.plants` | `billing.plants` (id, brand, vendor id, version, time zone) | Billing |
| `plants.brands` | new: code, display name, adapter, enabled | |
| `plants.brand_calls` | `private.sunsynk_calls` | Reading |
| `private.inverters`, `private.meta` | stay where they are; owner set to this part | Reading |
| `plant_config` settings and detection columns | stay; owner set to this part | Plants |
| `private.link_attempts` | stays; owner set to this part | Data logins |

Billing gives up `logins`, `login_plants`, `plant_claims`, `plants`. It keeps `seats` and the
trial facts (`trial_used_at`, `trial_used_by` move to `billing.plant_trials`).
`history_purged_at` and the `plant_config` history bookmarks stay where they are until step 3.

The reader ("Reading") owns `readings`, `strings`, `agg_minute`, `private.gaps`,
`private.poll_runs`, and nothing else.

**Front door.**
- Browser: edge `link` (today `link-sunsynk`, with a brand field), `claim-share`, `api_logins`,
  `api_link_remove`, `api_plant_states`.
- Other parts: `plants.*` functions only: `user_plants(user)`, `plant_for(brand, vendor_id)`,
  `vendor_of(plant)`, `login_of(plant)`, `tz(plant)`, `bump(plant)`, `remove_login(login)`,
  `list_seen(login, plants, at)`, and the figure functions in R22.

## Rules

Each rule has the check that proves it. The step is done when every check passes.

**Ownership**

- **R1. Every table has one owner part, and only that part writes it.** `supabase/owners.json`
  maps each table to a part, and each part to its function files. CI reads every function file
  and fails on an `insert`, `update` or `delete` into a table another part owns.
  *Check:* a test function in `SF/billing/` that updates `plants.logins` fails `npm test`.
- **R2. Other parts read this part's tables only through `plants.*` functions.** Billing's
  `reading_routes` and `poll_jobs_v2` stop joining `login_plants`; the email guard stops
  joining `sunsynk_accounts` and `plant_users`.
  *Check:* the same CI scan fails on a `from plants.<table>` outside this part's files. The
  known list starts at today's readers (34 files read `plant_users`, 17 read `login_plants`)
  and must be 0 at the end of the step.

**Logins**

- **R3. One row per login, in `plants.logins`.** Columns: id, account, brand, kind
  (`login`/`share`), username, refresh secret (Vault id), access token and expiry, status,
  linked, last ok, last error, last try. The status-copy trigger
  `sunsynk_accounts_billing_status` (0246:339) and `billing.login_status_follow` are dropped.
  *Check:* both old tables and the trigger are gone; link, then remove, leaves 0 rows for that
  login in any table.
- **R4. One set of status words:** `ok`, `needs_reconnect`, `disabled`. Today's
  `active`/`needs_relink` mapping (`login_status_follow.sql:8-12`) goes.
  *Check:* a check constraint; an insert with `active` fails.
- **R5. "May this user add a login" is one function,** `plants.link_allowed(user, brand)`.
  Today it is in `link-sunsynk:69-74`, `link_login_allowed` and `billing.link_login`.
  *Check:* a test per refusal reason; `link` calls only this function.
- **R6. Tokens stay private.** The browser roles cannot read `plants.logins`.
  *Check:* a select as `authenticated` and as `anon` returns 42501.

**Plant lists**

- **R7. One list row per login and plant, in `plants.login_plants`.** Columns: login, plant,
  name, linked, last seen, missing since, gone at. Plants reached through a share claim are in
  `plants.claims`. "Which plants does this user see" is one function, `plants.user_plants(user)`;
  `my_plant_ids` and every reader call it.
  *Check:* `plant_users` and `billing.login_plants` are dropped; on the rehearsal copy,
  `user_plants` equals the old `plant_users` set for every user (difference 0).
- **R8. The "gone after 50 minutes" rule is written once,** in `plants.list_seen`. It is the
  only writer of `missing_since` and `gone_at`, for own logins and the share login. The 50
  minutes is a setting (`app_config`), not a literal. A plant that goes queues one mail, as
  today's three copies do (`plant_users_upsert.sql:34`, `login_seen.sql:31`,
  `share_sync.sql:33`).
  *Check:* `interval '50 minutes'` appears 0 times in `SF/`; tests: missing 49 min stays,
  51 min is gone with one mail, back after gone clears both columns, share claim released.
- **R9. A plant list that fails part way changes nothing.** The adapter returns the whole list
  or an error; `list_seen` is called only with a whole list.
  *Check:* the fake brand fails on page 3 of 5; no row changes.

**Our own plant id**

- **R10. `plants.plants.id` is ours.** The 23 existing plants keep their id (no history
  rewrite). New plants get ids from a sequence that starts at 1,000,000,000,000. A check allows
  an id below that only for an old row where `brand = 'sunsynk' and vendor_id = id::text`.
  *Check:* the 23 rows pass the check; a new plant's id is at or above 1e12.
- **R11. The brand's id is `vendor_id text`, unique with brand,** and one function,
  `plants.plant_for(brand, vendor_id)`, finds or makes the plant. The three
  `insert ... on conflict (id) do nothing` paths (`link_login.sql:36`, `login_seen.sql:19`,
  `claim_plant.sql:11`) go. Claims take `(brand, vendor_id)`, not a bigint.
  *Check:* two concurrent `plant_for` calls for one new plant make one row; CI fails on
  `on conflict (id)` into `plants.plants`, and on `::bigint` applied to a vendor id.
- **R12. The vendor id leaves the database only toward the brand adapter.** Jobs carry both
  `plant` and `vendor_plant`. TypeScript has two branded types, `PlantId` and `VendorPlantId`;
  adapter functions take only the second, storage functions only the first.
  `getPlantDetail`, `plantfeed` (recover, sync-plant-energy), inverter `plantId` and the claim
  by id or serial all translate at the edge of the adapter.
  *Check:* `deno check` passes; a two-brand test where brand B's vendor id equals an existing
  plant's own id (e.g. "495944") makes a separate plant with separate readings, claims and
  routes.
- **R13. Test and fake plants never share our id with their vendor id.** The fake brand and
  every fixture use own ids at 1e12+. The fake tester plants in production (`@mock` logins,
  SOLAR-270) move to brand `mock` and new own ids, as the first live use of R10-R12.
  *Check:* a fixture scan finds no plant with `id::text = vendor_id` outside the 23 real ones.

**Brand interface**

- **R14. One interface, `EF/_shared/brands/types.ts`.** It covers: log in, renew a token,
  list plants, list inverters, read now (one inverter, all its parts), read history (one
  inverter, one day), read plant days (energy totals). Errors are typed: `auth`, `rate`,
  `vendor_down`, `ours`. Today "ours or SunSynk's" is a text match (`poller.ts:90,107`). Each
  call is counted per brand and kind. SunSynk is the first adapter, `EF/_shared/brands/sunsynk/`,
  built from the client half of `_shared/sunsynk.ts` (920 lines today) and `_shared/extract.ts`.
  *Check:* the fake brand `mock` and SunSynk (against `mock-sunsynk`) pass the same contract
  tests; `poll`, `link`, `claim-share`, `recover`, `sync-plant-energy` import only `types.ts`
  and a brand registry.
- **R15. "sunsynk" lives only in its adapter folder, its mock, and as data** (a row in
  `plants.brands`, `brand` values in rows). F20 known uses for `supabase/**` (248 lines in 29
  edge files, 144 lines in 57 SQL files today) go to 0 outside those. Screen and mail text that
  names the brand reads `plants.brands.display_name`; the frontend link screen's SunSynk help
  moves into one brand file. Mail text in `_shared/text.ts` is step 4.
  *Check:* `npm test` (F20) with the shrunk known list.
- **R16. Vendor outage state is per brand.** `email_system_state.sunsynk_down` and the call
  table become per brand, so one brand's outage does not mute another's alerts (0174:126).
  *Check:* with two brands, `mock` down for 10 minutes, a SunSynk plant's grid-off alert is
  still sent.

**Reader**

- **R17. The every-minute reader reads and saves, nothing else.** Each side job runs as its own
  cron job, on its own minute per login (hash of the login id, as `tempMinute` does):

  | Job | Today | Moves to |
  |---|---|---|
  | Plant list sync, hourly | `poller.ts:449-457`, `sunsynk.ts:625-644` | `plant-sync` job |
  | Inverter list refresh, 10 min | `poller.ts:427-436` | `plant-sync` job |
  | Share-login list check | `poller.ts:437-447` | `plant-sync` job |
  | Feature, battery-bank, battery-sign detection | `poller.ts:569-591` | `plant-check` job (database only) |
  | Temperatures, 10 min | `poller.ts:476-483` | `temps` job (moves to History in step 3) |
  | Alert step | `poll/index.ts:~200` (`email_poll_step`) | `alerts` job, after the minute's saves |
  | Share-login retry | `poll/index.ts:106-129` | `plant-sync` job |
  | Call report, heartbeat | `poll/index.ts:73-87,~225` | `job-check` |

  `email_poll_step` stops writing `last_try*` on logins (0231); the reader's save writes them.
  *Check:* `poll` imports none of these; `job-check` alerts when any of the new jobs stops
  (F12); a 2-hour local run shows each job on its minutes.
- **R18. The reader's door stays as it is:** routes from Billing, set-based, with `ends_at`;
  one batch save `poll_commit_batch` with the plant version fence, lock order logins then
  plants; newer token wins.
  *Check:* today's state tests and the billing-ends load run (0 rows after `ends_at`) pass.
- **R19. First try: the reader on a Supabase queue (pgmq), short calls only.**
  1. Each minute, cron sends one message per login (one per plant batch of at most 10 for the
     share login), delayed to its read second.
  2. Every 5 s, cron posts `ceil(visible / 10)` consumer calls through pg_net, capped.
  3. A consumer reads at most 10 messages (visibility 25 s), reads them with a 15 s deadline
     per read, saves in one batch and deletes the messages in the same transaction, then
     answers. No background work after the answer.
  4. A killed call's messages come back after 25 s and are read again inside the 50 s
     deadline. Past 50 s a read is dropped and the minute is left for recover.
  5. The drain loop (`drain(n)`) lives in `_shared`; the edge function is a thin caller, so
     the worker can run the same loop on the same queue.
  6. Token renewal under a row lock on the login, re-read after the lock.
  *Check:* R20.
- **R20. Load test at 1,000 logins against the fake SunSynk** (`load-test/v3/`, production
  timings), 30 minutes normal, then a 2-hour soak, then the slow run. Pass marks:

  | Measure | Pass |
  |---|---|
  | Plant-minutes lost, not caused by SunSynk | 0.1% or less, no minute over 1% |
  | Read second to saved | p95 15 s or less, p99 40 s or less |
  | SunSynk calls per inverter reading | 4.5 or less (today 4.3) |
  | Overlapping reads of one login, forced reconnects | 0 |
  | Rows written after `ends_at`, refused stale writes saved | 0 |
  | Slow run (5% of calls 10-20 s, 5% 429) | lost 0.5% or less, p95 25 s or less |

  *Check:* numbers written into this page and on SOLAR-681.
- **R21. Decision point.** The queue reader goes live only if every R20 mark passes after at
  most one round of fixes, inside a 3-day box. Any miss, or a backlog that grows, and the
  reader moves to the always-on worker (SOLAR-663: Fly.io, Frankfurt, one active copy and a
  fenced standby), running the same `drain` loop. Either way, today's poller stays one switch
  away (`private.poll_mode`) until the new reader has run a week in production.
  *Check:* the decision and its numbers are on SOLAR-681 before the switch.

**Same figures everywhere**

- **R22. Each plant figure this part owns has one function.** App, mail, push and alerts call
  it; none works it out again.

  | Figure | One function | Today also worked out in |
  |---|---|---|
  | Live power: solar, home, grid, battery (W) | `plants.live(plant)` | `api_overview`, `api_plant_states` |
  | Battery % now and at a time | `plants.soc_at(plant, ts)` | `notify:72-76` (`socAt`), `email_plant_events.sql:75-78` |
  | Grid on or off now | `plants.grid_on(plant)` | `poller.ts:136`, `q_grid_present`, `rollup_partition` |
  | Today's kWh: solar, home, grid in, battery in and out | `plants.day_energy(plant, day)` (today `_plant_day_energy`) | `api_overview:163-165` |
  | Independence % for a span | `plants.independence(plant, from, to)` | `notify:87` only (no `api_*` has it) |
  | Peak power on a day | `plants.peak(plant, day)` (today `q_day_peak`) | |
  | Outage length | `plants.outage(plant, event)` | `_shared/text.ts:722` (`lasted`) in `notify` |
  | Plant name for a user | `plants.name(plant, user)` | `notify`, `email_enqueue_plant` |
  | Plant's local day | `plants.tz(plant)` + `local_day` | 23 SQL files with a literal zone |

  Money figures ("est. saved") wait for step 5; history figures (best day, week, month) for
  step 3.
  *Check:* one test per figure: for a fixture plant and time, the value the app gets from its
  `api_*` equals the value the mail builder puts in the mail. A guardrail rule fails on new
  math for these in `EF/notify*`.

**Security**

- **R23. `api_link_disconnect` is revoked from `authenticated`** (Review L item 1; granted in
  0102:791). It is folded into `plants.remove_login` and dropped when `api_link_remove` stops
  calling it.
  *Check:* a call as `authenticated` returns 42501; then the function is gone.

**Data moves and time zone**

- **R24. Each move runs: new, copy, compare to zero, switch, drop.** Backup first (`pg_dump` of
  the touched schemas plus the Supabase daily backup checked). Each move is rehearsed on a
  local copy of production data first (F10). The compare is a SQL query that lists every
  difference; it must return 0 rows before the switch. Drop comes one release after the
  switch.
  *Check:* rehearsal log with compare = 0; the same log from production.
- **R25. Each plant has its time zone on `plants.plants.time_zone`** (IANA, not null, checked
  against `pg_timezone_names`). It is copied from `plant_config.timezone`, which then goes. A new
  plant takes its account's market `default_time_zone` (`billing.markets`); the brand's
  location is not used (location comes later, from Google Maps). `plant_tz()` reads the new
  column. No code names `Africa/Johannesburg`: today 23 SQL files do.
  *Check:* F20 count for the zone is 0 outside market data; a test plant in `Europe/London`
  gets its own local day, today and peak.

## Order of work

1. R23 (revoke, XS), R1 and R2 scans in CI with today's known lists. Nothing moves yet.
2. R14, R15, R16: brand interface and SunSynk adapter, code only, same tables. Ships on
   today's poller.
3. R10-R13: own plant id on `billing.plants` first (sequence, `vendor_id`, `plant_for`,
   both keys in jobs). Fake tester plants re-keyed in production as the canary.
4. R3-R9, R24, R25: schema `plants`, data moves (logins, then lists and claims, then plants),
   readers moved table by table, old tables dropped.
5. R17: side jobs out of the reader.
6. R19-R21: queue reader, load test, decision; worker if needed.
7. R22: figure functions and their tests. Mail switches to them in step 4.

## Size

Large. About 3-4 weeks, of which the queue trial is boxed to 3 days and the worker, if
needed, adds about 1 week. About 60 SQL functions and 8 edge files change; the data is small
(26 logins, 33 list rows, 23 plants).

## Costs

| Item | Cost a month |
|---|---|
| Supabase Queues (pgmq) | $0 (extension in the current project) |
| Load test | $0 (local) |
| Worker, only if R21 fails | about $5-15 at 1,000 logins (two small Fly.io machines; assumed, confirm before creating) |
| Hosted trial on a Supabase branch, if chosen (Needs Brynne 2) | about $10 for 3 days (assumed) |

## Needs Brynne

1. Sign rules R1-R25 once.
2. Choice: the queue trial, local only or local plus a hosted branch. See the options sent with
   this page.
3. Choice: keep the 23 old plant ids (R10), or re-key every plant now. See the options sent with
   this page.
4. Each production release stays on his say-so.

## Where reviewers disagree

| Point | Fable | Astra | Taken |
|---|---|---|---|
| Where new plant ids start | 1e12: above any id seen, below 2^53, a wrong id finds nothing | one past the highest id (900006023): no range can be kept clear of unknown brands; types do the job | 1e12 and the types. A vendor id used by mistake then finds no plant, instead of another plant |
| Keep old ids | Yes, but a full re-key is cheapest now (312 MB) and shows the bug class on day one | Yes; the two-brand test exposes the bug without a rewrite | Keep (ticket); re-key offered as a choice |
| Save time pass mark | p95 15 s, p99 40 s | p95 25 s | 15 s; 25 s for the slow run |
| Calls per reading | 1.03 x 4.3 (about 4.43) | 4.75 | 4.5 |
| Skip the queue trial | Case for: the council said no edge-only shape holds; today's poller is good to ~500 logins and there are ~15 | Run it: short calls with re-delivery were never tested | Run it, boxed to 3 days |
| Fenced lease in the worker | The queue's visibility timeout may replace it; check stale saves first | Keep the fence | Keep the fence until the stale-save tests say otherwise |

## Case against

Large, and owners see nothing new. The queue trial may cost 3 days to learn what the council
already expected (edge-only readers fail). Keeping the old plant ids means two kinds of id
forever, and a missed vendor-id lookup works on every live plant. R12 and R13 are the only
guard against that.
