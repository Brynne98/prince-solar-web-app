# Rework step 2: logins, plants and reading

SOLAR-681, part of SOLAR-678. Signed by Brynne 2026-11-26: reader stays today's, proven at 500 logins; old plant ids kept. Reviewed by Sol and Neon
(draft 1: both "rework"; their findings are fixed below). Hard calls by Fable and Astra.

Owners see nothing new. After this step: one home for logins, one home for each login's
plant list, our own plant id, SunSynk behind a brand interface, and a reader that only reads.

Facts from production (read only, 2026-11-26): 26 rows in `private.sunsynk_accounts` (25
logins + the share login, which has no account), 25 in `billing.logins`; 33 in `plant_users`,
33 in `billing.login_plants`; 23 plants, all brand `sunsynk`, every one with
`id = external_id`, ids 495944..900006022. `plant_config.timezone` holds 4 zones.
`billing.markets.default_time_zone` exists. `private.poll_mode` was dropped in 0255:86.

Paths: `SF/` = `supabase/schemas/functions/`, `EF/` = `supabase/functions/`.

## What this part owns

New schema `plants`. One part, "Logins and plants", owns:

| Table | Replaces | From |
|---|---|---|
| `plants.plants` | `billing.plants` (id, brand, vendor id, version) + `plant_config.timezone` | Billing, Plants |
| `plants.logins` | `private.sunsynk_accounts` + `billing.logins` | Data logins, Billing |
| `plants.login_events` | `private.sunsynk_login_events` | Data logins |
| `plants.login_plants` | `public.plant_users` (own-login rows) + `billing.login_plants` | Plants, Billing |
| `plants.claims` | `billing.plant_claims` + `plant_users` share rows | Billing, Plants |
| `plants.brands` | new: code, display name, enabled | |
| `plants.brand_calls`, `plants.brand_state` | `private.sunsynk_calls`, `email_system_state.sunsynk_down` | Reading, Messages |
| `private.inverters`, `private.meta` | stay; owner set to this part | Reading |
| `plant_config` settings and detection columns | stay; owner set to this part | Plants |
| `private.link_attempts` | stays; owner set to this part | Data logins |

Billing gives up `logins`, `login_plants`, `plant_claims`, `plants`. It keeps `seats` and a new
`billing.plant_facts` (`trial_used_at`, `trial_used_by`, `history_purged_at`, and the
`plants_outbox` trigger, 0247:1224). `purge_now` already writes `history_purged_at`; step 3
decides whether History takes it. The `plant_config` history bookmarks stay until step 3.

Keys that point at the old tables and move with them (no cascade drops): `billing.seats`
(0240:97), `billing.history_fetches` (0246:532), `private.inverters` (0024:154),
`private.sunsynk_login_events` (0083:22). Triggers that move: `email_on_plant_user`
(0102:560), `email_on_relink`, `plants_outbox`.

The reader ("Reading") owns `readings`, `strings`, `agg_minute`, `private.gaps`,
`private.poll_runs`.

**Front door.**
- Browser: edge `link` (today `link-sunsynk`; the old name stays as an alias for one release,
  `public/link.jsx:99`), `claim-share`, `api_logins`, `api_link_remove`, `api_plant_states`.
- Other parts: `plants.*` functions only: `user_plants(user)`, `plant_for(brand, vendor_id)`,
  `vendor_of(plant)`, `login_of(plant)`, `tz(plant)`, `bump(plant)`, `remove_login(login)`,
  `list_seen(login, plants, at, mode)`, `link_allowed(user, brand, username)`, and the figure
  functions in R23.

## Rules

Each rule has the check that proves it. The step is done when every check passes.

**Ownership**

- **R1. Every table has one owner part, and only listed files write it.** `supabase/owners.json`
  gives each table its owner part and the files that write it (SQL function files, edge
  files, `public/*.jsx`). `scripts/owners-check.mjs` (in `npm test`) fails on a write by a file
  not listed; `scripts/db-files.mjs` fails on a table with no owner. Lists only shrink. At the
  end of this step every writer of this part's tables is in this part's files
  (`SF/plants/`, `EF/_shared/brands/` and the plants edge code).
  *Check:* a new `update billing.logins` in any other file fails `npm test`; a new table
  without an owner fails `test:state`.
- **R2. Other parts read this part's tables only through `plants.*` functions.** The scan finds
  `from`, `join` and `using` on a table, qualified or found through `search_path`, in `SF/`,
  `EF/` and `public/`. Known readers today: 34 files read `plant_users` (including
  `EF/notify/index.ts:195,286,712`), 17 read `login_plants`. The known list must be 0 at the
  end of the step.
  *Check:* a new `join plants.login_plants` in `SF/msg/` fails `npm test`.

**Logins**

- **R3. One row per login, in `plants.logins`.** Columns: id, account (null only when
  `kind = 'share'`), brand, kind (`login`/`share`), username, refresh secret (Vault id), access
  token and expiry, status, linked, last ok, last error, last try, last try at. The status-copy
  trigger `sunsynk_accounts_billing_status` (0246:339) and `billing.login_status_follow` are
  dropped.
  *Check:* both old tables and the trigger are gone; link, then remove, leaves 0 rows for that
  login in any table; a `login` row with no account is refused.
- **R4. One set of status words:** `ok`, `needs_reconnect`, `disabled`. Today's
  `active`/`needs_relink` mapping (`login_status_follow.sql:8-12`) goes; the moved triggers use
  the new words.
  *Check:* a check constraint; an insert with `active` fails.
- **R5. "May this user add or reconnect this login" is one function,**
  `plants.link_allowed(user, brand, username)`. An existing username may always reconnect, as
  `link_login_allowed.sql:7` allows today. The edge calls it first; the locked write calls it
  again (today `link_login.sql:17`).
  *Check:* tests: a blocked account can reconnect its own username and cannot add a new one;
  the second call inside the write refuses a race.
- **R6. Tokens stay private.** The browser roles cannot read `plants.logins`.
  *Check:* a select as `authenticated` and as `anon` returns 42501.

**Plant lists**

- **R7. One list row per login and plant, in `plants.login_plants`;** share plants in
  `plants.claims`. `plants.user_plants(user)` answers "which plants do this user's logins and
  claims list" (membership). It is not the access rule: `my_plant_ids` stays Billing's, with
  its seat, route, purge and kept-elsewhere checks (`my_plant_ids.sql:7-17`); its route check
  reads membership through `plants.*`.
  *Check:* on the rehearsal copy, `user_plants` equals the old `plant_users` set for every user
  (difference 0), and `my_plant_ids` is unchanged for every user; an RLS test signed in as user
  A reads 0 rows of user B's plant.
- **R8. The "gone after 50 minutes" rule is written once,** in `plants.list_seen`, the only
  writer of `missing_since` and `gone_at`. The 50 minutes is a setting (`app_config`). Two
  modes, as today:
  - `sync` (hourly list, own logins and the share login): missing 50 minutes, then gone; one
    `plant_off_login` mail per plant on own logins (today `plant_users_upsert.sql:34`), claim
    released and owner mailed on the share login (today `share_sync.sql:33,53`).
  - `relink` (the owner signs in again): a plant not in the fresh list is gone at once, no
    mail (today `link_login.sql:53`).
  *Check:* `interval '50 minutes'` appears 0 times in `SF/`; separate tests for sync (49 min
  stays, 51 min gone with one mail, back clears both columns), relink, and share sync.
- **R9. A plant list that fails part way changes nothing.** The adapter returns the whole list
  or an error; `list_seen` is called only with a whole list.
  *Check:* the fake brand fails on page 3 of 5; no row changes.

**Our own plant id and inverter key**

- **R10. `plants.plants.id` is ours.** The 23 existing plants keep their id (no history
  rewrite). New plants get ids from a sequence starting at 1,000,000,000,000. A check allows an
  id below that only for the 23 listed old ids.
  *Check:* a new plant's id is at or above 1e12; inserting a new row with `id = vendor_id`
  below 1e12 fails.
- **R11. The brand's plant id is `vendor_id text`, unique with brand,** and one function,
  `plants.plant_for(brand, vendor_id)`, finds or makes the plant, inside the same transaction
  as the list or claim write. The three `insert ... on conflict (id) do nothing` paths
  (`link_login.sql:36`, `login_seen.sql:19`, `claim_plant.sql:11`) go. Claims take
  `(brand, vendor_id)`.
  *Check:* two concurrent `plant_for` calls for one new plant make one row; CI fails on
  `on conflict (id)` into `plants.plants` and on `::bigint` applied to a vendor id.
- **R12. The vendor id leaves the database only toward the brand adapter.** Every job row
  carries `plant`, `brand` and `vendor_plant`: poll routes, `history_take` (today
  `history_take.sql:65-70` sends no vendor id), recover, sync-plant-energy. TypeScript has two
  branded types, `PlantId` and `VendorPlantId`; adapter functions take only the second, storage
  functions only the first. `getPlantDetail`, `plantfeed`, inverter `plantId` and the claim by
  id or serial translate at the adapter's edge.
  *Check:* `deno check` passes; a two-brand test where brand B's plant id is "495944" makes a
  separate plant with separate readings, claims and routes.
- **R13. Inverter keys cannot collide across brands.** `inverters`, `meta`, `readings` and
  `strings` key on the bare serial (0001:40,46,142; `poll_commit_batch.sql:87`). SunSynk
  serials stay bare (no history rewrite); every other brand's serials are stored as
  `<brand>:<serial>`. The adapter adds and strips the prefix.
  *Check:* the two-brand test uses the same serial on both brands; two inverters, two sets of
  readings.
- **R14. Test and fake plants never share our id with their vendor id.** The fake brand and
  every fixture use own ids at 1e12+. The fake tester plants in production (`@mock` logins,
  SOLAR-270) move to brand `mock` and new own ids, as the first live use of R10-R13.
  *Check:* a fixture scan finds no plant with `id::text = vendor_id` outside the 23 old ones.

**Brand interface**

- **R15. One interface, `EF/_shared/brands/types.ts`.** It covers: log in, renew a token, list
  plants, list inverters, read now (one inverter, all its parts), read history (one inverter,
  one day), read plant days (energy totals). Errors are typed: `auth`, `rate`, `vendor_down`,
  `ours`; today "ours or SunSynk's" is a text match (`poller.ts:90,107`). Each call is counted
  per brand and kind. SunSynk is the first adapter, `EF/_shared/brands/sunsynk/`, built from
  the client half of `_shared/sunsynk.ts` (920 lines) and `_shared/extract.ts`.
  *Check:* the fake brand `mock` and SunSynk (against `mock-sunsynk`) pass the same contract
  tests; `poll`, `link`, `claim-share`, `recover`, `sync-plant-energy` import only `types.ts`
  and a brand registry.
- **R16. "sunsynk" lives only in its adapter folder, its mock, and as data** (a row in
  `plants.brands`, `brand` values in rows). The F20 known uses in `SF/` and `EF/` go to 0
  outside those, except `EF/_shared/text.ts` and `EF/_shared/email.ts` (mail text, step 4).
  Screen text that names the brand reads `plants.brands.display_name`; the link screen's
  SunSynk help moves into one brand file under `public/`.
  *Check:* `npm test` (F20) with the shrunk known list.
- **R17. Vendor outage state is per brand** (`plants.brand_state`, `plants.brand_calls`), so
  one brand's outage does not mute another's alerts (0174:126).
  *Check:* with two brands, `mock` down for 10 minutes, a SunSynk plant's grid-off alert is
  still sent.

**Reader**

- **R18. The every-minute reader reads and saves, nothing else.** Each side job runs as its
  own cron job, on its own minute per login (hash of the login id, as `tempMinute` does):

  | Job | Today | Moves to |
  |---|---|---|
  | Plant list sync, hourly | `poller.ts:449-457`, `sunsynk.ts:625-644` | `plant-sync` job |
  | Inverter list refresh, 10 min | `poller.ts:427-436` | `plant-sync` job |
  | Share-login list check | `poller.ts:437-447` | `plant-sync` job |
  | Share-login retry | `poll/index.ts:106-129` | `plant-sync` job |
  | Feature, battery-bank, battery-sign detection | `poller.ts:569-591` | `plant-check` job (database only) |
  | Temperatures, 10 min | `poller.ts:476-483` | `temps` job (History in step 3) |
  | Alert step | `poll/index.ts` `email_poll_step` call | `alerts` job |
  | Call report, heartbeat | `poll/index.ts` | `job-check` |

  Every login's outcome is recorded each minute, also when it saves nothing: the save writes
  it for logins that read, `account_mark` for logins that failed (today failed logins skip the
  save, `poller.ts:81-86`, and outage detection needs their `last_try`, `email_sweep.sql:24`).
  The `alerts` job reads committed minutes and outcomes from a cursor it moves only after a
  run succeeds, so a failed run is retried.
  *Check:* `poll` imports none of these; `job-check` alerts when any new job stops (F12); a
  SunSynk outage test still raises the outage alert; a failed alerts run is caught up next
  minute.
- **R19. One lock order for every writer: logins, then plants.** Poll save, relink, remove,
  status change, claim and list sync. Today `billing.link_login` locks plants before it
  updates the login (`link_login.sql:39`), the reverse of `poll_commit_batch.sql:36`.
  *Check:* a concurrency test runs a batch save, a relink and a remove on the same login 100
  times with no deadlock.
- **R20. The reader's save stays the one door:** routes from Billing, set-based, with
  `ends_at`; one batch save `poll_commit_batch` with the plant version fence; newer token wins.
  The save checks the route against the database clock after it locks, not a time the caller
  sends (today `p_at`, `poll_commit_batch.sql:63`).
  *Check:* today's state tests pass; a save that arrives after `ends_at` with an old `p_at`
  writes 0 rows.

**Reader host (decided 2026-11-26: today's reader, proven at 500 logins)**

- **R21. The reader stays on Supabase:** today's edge shards, posted each minute by pg_cron.
  No paid host and no paid branch until there are paying customers. It is tuned (shard size,
  dispatch spread, call cap, side jobs gone per R18) until it passes R22 at 500 logins.
  *Check:* R22.
- **R22. Load test at 500 logins against the fake SunSynk** (`load-test/v3/`, production
  timings, the 500 shape): 30 minutes normal, then a 2-hour soak that includes the hourly plant
  sync and the side jobs on their own minutes. Pass marks:

  | Measure | Pass |
  |---|---|
  | Plant-minutes missed (no `agg_minute` row once the minute is over) | 0 |
  | Reading age | every reading on screen within 5 s of the page's ask second (12-42 s past the minute, SOLAR-70): the page asks once more 5 s later when the minute is not saved yet, then waits for the next minute (`public/live-retry.mjs`). Signed by Brynne 2026-11-27 |
  | Rows written after `ends_at` | 0 |

  Today, at 500 logins, the old way missed 2 plant-minutes in 7 minutes and saved at p95 5.6 s
  (`poller-v3-design.md`, load test table). A read the fake fails (its 0.1% 504 tail) must be
  retried inside the minute to count as not missed.

  Worker trigger: the always-on worker (SOLAR-663) is built only when paying customers bring
  the login count near the proven ceiling: 400 logins (80% of 500), or any production day with a
  missed plant-minute not caused by SunSynk. `job-check` reports the login count each day.
  *Check:* the numbers on this page and on SOLAR-681.

**Same figures everywhere**

- **R23. Each plant figure worked out in two or more places gets one function.** App, mail,
  push and alerts call it. A figure with one consumer stays where it is.

  | Figure | One function | Worked out today in |
  |---|---|---|
  | Battery % now and at a time | `plants.soc_at(plant, ts)` | `api_overview`, `notify:72-76`, `email_plant_events.sql:75-78` |
  | Grid on or off | `plants.grid_on(plant, ts)` | `poller.ts:136`, `q_grid_present`, `rollup_partition` |
  | Today's kWh: solar, home, grid in, battery in and out | `plants.day_energy(plant, day)` (today `_plant_day_energy`) | `api_overview:163-165` (its own sums), `_plant_day_energy` |
  | Independence % for a span | `plants.independence(plant, from, to)` | `public/data.jsx`, `public/tabs.jsx`, `_energy_row.sql`, `notify:87` |
  | Outage length | `plants.outage(plant, event)` | `EF/_shared/text.ts:722` (`lasted`), app alerts |
  | Plant name for a user | `plants.name(plant, user)` | `notify`, `email_enqueue_plant`, `api_logins` |
  | Plant's local day | `plants.tz(plant)` + `local_day` | 23 SQL files with a literal zone |

  `notify` changes in this step anyway (it reads `plant_users`), so it moves to these functions
  now. Other mail and push code moves in step 4. Money ("est. saved") is step 5; best day,
  week and month are step 3.
  *Check:* one test per figure: for a fixture plant and time, the app's value (its `api_*`
  answer) equals the value `notify` puts in the mail. A guardrail rule fails on new math for
  these figures in `EF/notify*`.

**Security**

- **R24. `api_link_disconnect` is revoked from `authenticated`** (Review L item 1; granted at
  0102:791). It is folded into `plants.remove_login` and dropped when `api_link_remove`
  (its only caller) stops calling it.
  *Check:* a call as `authenticated` returns 42501; then the function is gone.

**Data moves and time zone**

- **R25. Each move runs: new, copy, compare to zero, switch, drop.**
  - Backup first: `pg_dump` of the touched schemas, plus a check that the Supabase daily backup
    is from today.
  - Rehearsed on a local copy of production data (F10), with writes running during and after
    the switch, and a way back tested.
  - Switch under a write fence: the copy, the final compare (a query listing every
    difference, 0 rows) and the switch of keys, triggers and functions run in one transaction
    that blocks writers to the old tables.
  - Order: `plants.plants` first, then `plants.logins` and `login_events`, then
    `login_plants` and `claims` (keys point that way).
  - Drop one release after the switch.
  *Check:* rehearsal log with compare = 0 and writes after the switch landing in the new
  tables; the same log from production.
- **R26. Each plant has its time zone on `plants.plants.time_zone`** (IANA, not null, checked
  against `pg_timezone_names`). It is copied from `plant_config.timezone`. A new plant takes the
  brand's zone if the adapter gives a valid one (as `sunsynk.ts:671` does today), else its
  account's market `default_time_zone`. `plant_tz()`, `plant_cfg()` and `api_me` read the new
  column, so the browser keeps its zone (`public/app.jsx:1593`, `tabs.jsx:150`). No code names
  `Africa/Johannesburg`: today 23 SQL files do.
  *Check:* F20 count for the zone is 0 outside market data; a test plant in `Europe/London` on
  a South African account gets its own local day, today and peak, in app and mail.

## Order of work

Each step ships on its own, on today's poller.

1. R24 (revoke, XS); R1 and R2 scans in CI with today's known lists.
2. R15: brand interface and SunSynk adapter, code only, same tables.
3. R3-R14, R25, R26: schema `plants` built with our own plant id and the inverter key from the
   start; moves in R25's order; readers moved table by table; old tables dropped one release
   later. Fake tester plants re-keyed as the canary.
4. R16, R17: brand strings and per-brand state, now that `plants.brands` exists.
5. R18-R20: side jobs out of the reader, outcomes for every login, one lock order, save on the
   database clock.
6. R21-R22: tune today's reader and run the 500-login load test until it passes.
7. R23: figure functions; app and `notify` switched; tests.

## Size

Large. About 3-4 weeks. The worker is not in this step. About 60 SQL functions and 8 edge files change; the data is small
(26 logins, 33 list rows, 23 plants).

## Costs

| Item | Cost a month |
|---|---|
| Reader | $0 (today's Supabase plan) |
| Load test | $0 (local) |
| Worker, later, at the R22 trigger | about $5-15 (two small Fly.io machines; assumed, confirm before creating) |

## Needs Brynne

- Signed 2026-11-26 (rules R1-R26). Reader: today's, proven at 500 logins (choice D).
  Plant ids: the 23 old ids kept, new ones from 1e12 (choice A).
- Each production release stays on his say-so.

## Where reviewers disagree

| Point | View | Taken |
|---|---|---|
| Where new plant ids start | Fable: 1e12, a wrong id then finds nothing. Astra: one past the highest id; no range is safe from unknown brands, types do the job | 1e12 and the types |
| Keep old ids | Fable: keep, but a full re-key is cheapest now (312 MB) and shows the bug class on day one. Astra: keep; the two-brand test finds the bug without a rewrite | Keep; re-key offered as choice 2 |
| Queue trial | Astra: run it, short calls with re-delivery were never tested. Fable: run it boxed, but the council already said no edge-only shape holds. Neon: cut it; 25 logins, today's poller holds to ~500 | Brynne: no trial; today's reader proven at 500 |
| Same figures in this step | Neon: defer to step 4, mail has no new consumer yet. Sol: cut single-consumer wrappers | Kept for figures worked out in two or more places; `notify` moves now as it is touched anyway |

## Case against

Large, and owners see nothing new. Keeping the old plant ids means two kinds of id for good,
and a missed vendor-id lookup works on every live plant; R12 and R14 are the only guard. The
same holds for inverter serials (R13). Today's reader is proven only to 500 logins; at
the trigger, the worker must be built before more customers come.

## Built (2026-11-27)

Branch `solar-681-logins-plants-reading`. One migration, `0283_plants_schema.sql`, with the
moves, the compares and every rewritten function. Nothing released yet.

| Rule | Done | Proof |
|---|---|---|
| R1 | Owner per table in `supabase/owners.json`; only listed writers | `npm test` (owners-check); `test:state` (db-files: every table has an owner) |
| R2 | 0 reads of this part's tables outside it; other parts read `plants.*` views without tokens, or functions | owners-check, `parts.plants.readers` empty |
| R3-R6 | `plants.logins` one row per login; status words ok / needs_reconnect / disabled; one link check; no browser read | plants-tests R3, R4, R6; 931 billing checks |
| R7-R9 | `plants.login_plants` + `plants.claims`; `plants.list_seen` the one gone rule (sync, relink); whole list or a throw | billing checks SH1-SH3, V13, W3, W4; plants-tests |
| R10-R12 | Old 23 ids kept; new ids from 1e12; `plants.plant_for`; jobs carry the brand's id | plants-tests R10-R12 |
| R13, R14 | Brand `mock` for the fake tester plants, serials `mock:<serial>`; the move is in 0283 | plants-tests; rehearsal below |
| R15 | Brand interface, SunSynk adapter, `mock` adapter; contract tests for both | `brands/contract_test.ts` (deno) |
| R16 | No brand name in shared code outside the adapter, mock and mail text (step 4) | reuse-check (F20) |
| R17 | Outage state and call counts per brand | plants-tests R17 |
| R18 | Reader reads and saves; alerts, plant checks (SQL), plant sync, temperatures (poll tasks) on their own | 2-hour soak: each job every minute |
| R19 | One lock order | lock-order races 5 and 6, 20 runs each, 46 races in all, no deadlock |
| R20 | Save checks routes on the database clock | plants-tests R20 |
| R21-R22 | Today's reader, groups at 0/2/4 s, one retry on a brand 5xx and on a gateway 502-504 | load tests below |
| R23 | One function each: independence, span totals, battery %, grid on/off (`public.grid_live`); outage length one formatter (`text.ts minutesText`) | plants-tests R23; contract test (threshold) |
| R24 | `api_link_disconnect` gone | plants-tests R24 |
| R25 | New, copy, compare, switch, drop in one transaction; rehearsed | below |
| R26 | Plant zone on `plants.plants`; brand's zone, else the market's | plants-tests R26 |

**Load tests, 500 logins, fake SunSynk with production timings (local):**

| Run | Plant-minutes | Missed | Saved after the page asked | Save p95 |
|---|---|---|---|---|
| Baseline, groups at 0/10/20 s | 4,500 | 0 | 774 (17%) | 24.5 s |
| 30 min, groups at 0/2/4 s | 14,500 | 4 (a local gateway 502; read retry added) | 37 (0.26%) | 8.6 s |
| 2-hour soak, side jobs on | 57,502 | 0 | 141 (0.25%) | 8.6 s |

The soak's late saves are reads the fake held 10 s or more (its 504 tail). Brynne's decision
(2026-11-27): the page keeps its 12-42 s ask and asks once more 5 s later; R22's reading age is
now "on screen within 5 s of the ask second".

**Rehearsal on a production copy** (read-only copy of the login, plant and billing tables,
emails masked, no tokens): 24 accounts, `account_state` the same before and after (0
differences once the fake plants' new ids are mapped); plant lists the same both ways; 21
fake plants moved to brand `mock` with ids from 1e12, 24 serials prefixed, 22 logins brand
`mock`, no login listing another brand's plant.

**Left open, on purpose:**
- `plant_config` still has writers outside this part: History's bookmarks (`recover`,
  `plant_start_fill`, `purge_now`, step 3) and the browser's own settings (`public/data.jsx`,
  column grants). Listed in `owners.json`.
- The save checks a plant's route, not each (plant, login) pair: a sample from a login whose
  route ended passes while another route to the plant is live (Sol, final review). As before
  this step.
- Message kinds and mail words that name SunSynk (`sunsynk_down`, `text.ts`): step 4.
- Kept names: the admin page's `sunsynkUser` key and the PostHog event `sunsynk_calls_counted`;
  the `link-sunsynk` alias goes one release after the frontend calls `link`.
