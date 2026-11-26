# Review L: architecture of Prince Solar Hub

2026-11-25. Code at origin/main `15acfea`; main moved to `4d2df05` during the review (poll code moved to `_shared/poller.ts`), and reading line refs below are from `4d2df05`. Read only. Reviewers: own read, Neon (gemini-4-neon),
Astra (gpt-6.2-astra), Fable (claude-fable-5-2). Sol was started, then cancelled on request. Each reviewed the seven parts on its own,
then the findings were merged. Every claim used below was checked against the code.
Paths: `NNNN` = `supabase/migrations/NNNN_*.sql`, `fn:` = `supabase/functions/fn/index.ts`.

## Summary

| Part | Score | Worst problem |
|---|---|---|
| 1 Accounts | 6 | One delete function reaches into five other parts' tables and lock order (0252:354) |
| 2 Data logins | 4 | Every login stored twice: `private.sunsynk_accounts` and `billing.logins`, kept in step by a trigger and dual writes |
| 3 Plants | 4 | Plant id is SunSynk's own number; "which user has which plant" kept in two tables with the same "gone after 50 min" rule twice |
| 4 Reading | 7 | Good front door (`poll_jobs_v2`, `poll_commit_v2`, version check); the minute job also does alerts, plant sync, share retry, detection |
| 5 History | 4 | Two first-import engines: `plant_config.backfill_*` and `billing.history_fetches`; screens and the "history ready" mail only see the first |
| 6 Billing | 7 core / 5 scope | Well-built inside, but it now owns logins, plants, reading decisions, deletes, the history queue and its own email outbox |
| 7 Messages | 5 | Not one queue: `email_queue`→`msg.outbox`, a second `billing.outbox`, Supabase Auth mail, and `error-alert` straight to Resend |

Scores are for the part's own design. Spread between reviewers is in "Where reviewers disagree".

## The seven parts

### 1. Accounts: 6/10

- **Owns:** `auth.users` (Supabase Auth), `public.profiles`, `email_prefs`, `push_prefs`.
- **Front door:** Supabase Auth from `public/auth.jsx`; `api_me`, `api_prefs_set`, `api_account_delete`.
- **Problems:**
  1. `api_account_delete` (0252:354) deletes from `billing.*`, `private.sunsynk_accounts`, `vault.secrets`,
     `private.inverters`, `plant_users`, writes `email_queue`, then `profiles` and `auth.users`. It must
     copy the lock order of linking, claims and the poller (comment at 0252:360). Each new part
     must remember to add itself here.
  2. "The account" is three rows made at three times: `auth.users`, `profiles` (trigger at sign-up,
     0027:134, still has a dead `plan free/pro` column), `billing.accounts` (made lazily on first
     billing call, 0247:49).
  3. Account mail goes two ways: confirm/reset through Supabase Auth + Infobip SMTP
     (`_shared/email.ts:11`), `account_deleted` through `email_queue` (0252:385).

### 2. Data logins: 4/10

- **Owns:** `private.sunsynk_accounts` (tokens, status), Vault secrets, `private.link_attempts`,
  `billing.logins`, `billing.plant_claims`; `link-sunsynk`, `claim-share`, `_shared/sunsynk.ts`, `_shared/links.ts`.
- **Front door:** `link-sunsynk`, `claim-share`, `api_logins`, `api_link_remove`.
- **Problems:**
  1. One login, two rows with the same id: `private.sunsynk_accounts` and `billing.logins`
     (0240:50). Status is copied by trigger `sunsynk_accounts_billing_status` (0246:340); link,
     claim, remove and the hourly plant list each write both.
  2. `public.api_link_disconnect` is still callable by signed-in users (grant 0102:791, never
     revoked). It is owner-checked, so no other user's data is at risk, but called directly it
     deletes the `sunsynk_accounts` row and skips `billing.remove_login`, leaving `billing.logins`
     and its seats behind. `api_link_remove` (0252:322) calls it as a step. Size XS to revoke.
  3. `_shared/sunsynk.ts` (920 lines) mixes the SunSynk client, token storage, plant sync,
     `plant_config` seeding, poll job reading and batch cursors. Pre-switch branches still live in
     `link-sunsynk:68-90` and `links.ts`, although `billing.is_live()` is now always true (0252:17).

### 3. Plants: 4/10

- **Owns:** `plant_users`, `plant_config`, `config_changes`, `billing.plants`, `billing.login_plants`,
  `billing.seats`, `private.inverters`, `private.meta`.
- **Front door:** `api_plant_states`, `api_choose_plants`, `my_plant_ids`, `chosen_plant_ids`; the
  browser writes 7 columns of `plant_config` directly (`public/data.jsx:435`, grant 0196:30).
- **Problems:**
  1. Plant id is SunSynk's number. `billing.plants` has `(brand, external_id)` but `link_login` inserts
     `id = external_id = SunSynk id` and ignores conflicts on `id` (0242:186). Every reading table
     keys on that id. A second brand with the same number joins the existing plant: access,
     billing and history all mix.
  2. "Which plants a login sees" is in two tables: `plant_users` (`share_missing_at`,
     `share_gone_at`) and `billing.login_plants` (`missing_since`, `gone_at`). `syncPlants`
     writes both in two calls (`_shared/sunsynk.ts:628,635`); a failure of the second is only noted,
     so the lists can drift.
  3. `plant_config` has three owners: owner settings (tariff, battery), detection (`has_grid`,
     `batt_positive_means`), and history bookmarks (`backfill_next`, `temp_next`). A trigger on the
     bookmarks sends mail (0102:545). `plant_users_upsert` still seeds the single-site
     `CALIBRATION_PLANT` (0252:240).

### 4. Reading: 7/10

- **Owns:** `readings`, `strings`, `agg_minute`, `private.gaps`, `private.poll_runs`, `private.sunsynk_calls`;
  `poll`, `_shared/extract.ts`.
- **Front door:** `poll_jobs_v2` (which plants, through which login) and `poll_commit_v2` (one
  transaction, refuses a write whose plant version moved, 0246:184-255). Screens read through `api_*`.
- **Problems:**
  1. The minute job does more than read: share-login retry (`poll:120`), plant list sync
     (`_shared/poller.ts:442,452`), feature and battery-sign detection (`poller.ts:574-588`), temperatures
     (`poller.ts:184`), and alert steps through `email_poll_step` (`poll:211`), which writes login state and alert state.
  2. Scale limits are known: ~500 logins (SOLAR-663), shared login in one shard (SOLAR-649).
     `poll_jobs_v2` works out `billing.account_status` for the fleet on each shard call (0246:99).
  3. Single brand: 5-endpoint SunSynk shape and `pvIV[0].time` freshness gate are in the poller
     itself, not behind an adapter (covered by SOLAR-647).

### 5. History: 4/10

- **Owns:** `agg_5m`, `readings_5m`, `strings_5m`, `inverter_history*`, `plant_energy`,
  `private.rollup_progress`, `private.refill_queue`, `private.recover_kicks`; `recover`,
  `sync-plant-energy`, `_shared/invhistory.ts`, `_shared/plantfeed.ts`. Plus, in Billing's schema,
  `billing.history_fetches` and `history_lanes`.
- **Front door:** `q_insert_recovered_v2`, `q_insert_inverter_history_v2`, `q_upsert_plant_energy_v2`
  (all version-checked), `private.plant_readings_delete`, `_plant_day_energy`.
- **Problems:**
  1. Two 60-day import engines. A new link walks `plant_config.backfill_next..backfill_until`
     (`recover:344-390`, kicked by 0235). A seat switch or restart uses `billing.history_fetches`
     (`recover:529-575`, 0246:529-820). `recover` must leave one to the other (`recover:592`). Only
     the old bookmarks drive "Fetching history" and the history-ready mail (trigger 0102:545); nothing
     outside billing reads `history_fetches`.
  2. Progress kept in three places: `plant_config` bookmarks, `billing.history_fetches`, and
     `app_config` round-robin cursors (`_shared/sunsynk.ts:819-828`).
  3. 0266 slices only `readings` and `strings`. `agg_minute_rollup(31)` still rolls up and deletes in
     one statement (0072:57, scheduled 0082:196). Overlaps SOLAR-653. `recover` and
     `sync-plant-energy` walk every plant in one 110 s run (SOLAR-647). 0235:59,81 hard-code the
     production functions address.

### 6. Billing: 7/10 inside, 5/10 for scope

- **Owns:** schema `billing` (26 tables, ~120 functions): accounts, markets, plans, prices, seats,
  subscriptions, invoices, payment attempts and events, refunds, grants, an event log.
- **Front door:** `billing` edge function (`/pay`, `/change`, `/verify`, `/webhook`, `/run`),
  `billing_v2`/`billing_jobs`, `api_account_state`, `api_plan_quote`, `billing.plant_state`,
  `billing.account_state`.
- **Good:** stored facts only, state worked out from them; commands carry `at`; attempts, invoices
  and provider events are separate durable rows; version numbers stop stale checkouts and writes.
- **Problems:**
  1. Scope creep. Billing owns logins and plants (0240:50-106), decides reading (`reading_routes`),
     runs deletes (`delete_due` calls `plant_readings_delete`, 0246:486), runs the history queue
     (0246:529), and has its own email outbox with its own lease and retry (0244, 0247:1385-1501).
  2. Clock jobs loop over everyone in PL/pgSQL: `outbox_sweep` runs `account_status` for every
     account every minute (0247:1253, called from `notify:430`); `delete_due` and `billing.alerts`
     loop `plant_state` over every plant every 5 minutes (0246:501, 843).
  3. One market assumed: `account_of` raises "which market?" once a second market exists (0247:47).

### 7. Messages: 5/10

- **Owns:** `email_queue` (event log), `msg.kinds`, `msg.outbox`, `msg.push_sends`, `push_subs`,
  `private.*_alert_state`, `private.email_system_state`; `notify`, `notify-email`, `notify-push`,
  `unsubscribe`, `error-alert`, `_shared/email.ts`, `_shared/text.ts`, `_shared/pace.ts`.
- **Front door:** insert into `public.email_queue` (a trigger routes it to `msg.outbox`, 0261:145);
  `email_poll_step`; `api_alerts`, `api_notifications`, `api_push_sub`.
- **Is it one queue? No.** Four send paths:
  | Path | Queue | Retries | History |
  |---|---|---|---|
  | Alerts, reports, welcome, history, account deleted | `email_queue` → `msg.outbox` | Messages | Messages |
  | Receipts, renewals, card, plan ended, win-back | `billing.outbox` | Billing (`outbox_done`, 0247:1454) | Billing |
  | Sign-up confirm, password reset, password changed | Supabase Auth → Infobip SMTP | Supabase | Infobip logs (`job-check:78`) |
  | Error alerts to admin@ | none, straight to Resend (`error-alert:36`) | PostHog resends | none |
  Sending code is shared (`notify` sends both outboxes, one Resend pace), but queue, retry and
  history are not.
- **Problems:**
  1. Two outboxes with the same lease, retry, 429 and Resend-error logic built twice
     (`notify:428-473` and `notify:527-644`).
  2. The send-time guard `msg.email_guard` (0263:54-89) knows each kind's product rules and reads
     `plant_users`, `sunsynk_accounts`, `billing.seats`, `billing.accounts`, `auth.users`. Re-checking at
     send time is right; the rules belong to the part that queued the message.
  3. Building mail reads other parts' tables directly: `agg_minute` (`notify:73`), `plant_config`
     (`notify:103,196`), `plant_users` (`notify:195,286`), `plant_energy` and `email_queue` (`notify:215`).
- Kept on purpose, not a finding: no List-Unsubscribe on alert mail (`_shared/email.ts:8`).

## Joins

| From → to | Where | Rating |
|---|---|---|
| Browser → all parts | `api_*` RPCs, `/functions/v1/link-sunsynk`, `claim-share`, `billing/*` (`public/data.jsx`, `public/link.jsx:23`) | Clean |
| Browser → Plants, Messages | direct table writes: `plant_config` (`data.jsx:435`), `email_prefs`, `push_prefs` (`data.jsx:440-479`) | Tangled (column grants, not a function) |
| Accounts → every part | `api_account_delete` (0252:354-391) | Tangled |
| Accounts → Messages | trigger `email_on_confirm` on `auth.users` inserts `email_queue` (0102:524) | Clean |
| Data logins ↔ Billing | trigger `sunsynk_accounts_billing_status` (0246:340); dual writes in `link_login_live`, `share_claim_*`, `api_link_remove` (0247:418-556, 0252:306-328) | Tangled |
| Data logins → Plants, Billing | `syncPlants` writes `plant_users_upsert` then `login_seen`, two calls (`_shared/sunsynk.ts:628-637`) | Tangled |
| Data logins → Messages | `plant_users_upsert`, `share_sync` insert `email_queue` (0252:231, 0247:538) | Clean (the queue is the door) |
| Data logins → Messages | `link-sunsynk:92` reads `email_queue.sent_at` for an analytics event | Tangled |
| Reading → Billing | `poll_jobs_v2` → `billing.reading_routes`; `poll_commit_v2` → `billing.write_allowed` (0246:99-255) | Clean |
| Reading → Data logins | `poll_commit` writes `private.sunsynk_accounts` (0250:105-114); `account_mark` (`_shared/poller.ts:84`) | Tangled |
| Reading → Messages | `poll` calls `email_poll_step` (`poll:211`), which writes `sunsynk_accounts.last_try*` and alert state (0231) | Tangled |
| Billing → Messages | `billing.readings_start` writes `private.plant_alert_state` (0256:58); `billing.outbox` calls `email_wanted`, `email_unsub_token` (0254:981,1113) | Tangled |
| Billing → History | `purge_now` calls `plant_readings_delete` and clears `plant_config` bookmarks (0246:477-479); `history_take` joins `sunsynk_accounts`, `plant_config` (0246:736) | Tangled |
| History → Billing | `recover` drives `billing_jobs` `history_take/step/renew/fetching` (`recover:524-592`) | Tangled (History's queue lives in Billing) |
| History → Plants | `recover` updates `plant_config` bookmarks (`recover:208,223,377`); cursors in `app_config` (`_shared/sunsynk.ts:819-828`) | Tangled |
| History → Reading | guarded writes `q_insert_recovered_v2`, `q_upsert_plant_energy_v2` (`sync-plant-energy:125`) | Clean |
| Messages → Reading, History, Plants | `notify` reads `agg_minute`, `plant_energy`, `plant_config`, `plant_users` (`notify:73-286`) | Tangled |
| Messages → Billing | `msg.email_guard` reads `billing.seats`, calls `billing.report_wanted` (0263:64-73) | Mixed: `report_wanted` clean, `seats` join tangled |
| Every part | advisory lock keys `(1, login)`, `(3, 0)`, `(8, 651)`, plant id, in 19 migrations | Tangled (an unwritten protocol) |

## Data two parts both own

| Fact | Copy 1 | Copy 2 |
|---|---|---|
| A login and its status | `private.sunsynk_accounts` | `billing.logins` |
| Which plants a login sees, names, "gone" | `public.plant_users` | `billing.login_plants`, `billing.plant_claims` |
| 60-day import progress | `plant_config.backfill_*`, `temp_next` | `billing.history_fetches` |
| Mail queue, retries, send history | `email_queue` + `msg.outbox` | `billing.outbox` |
| The account record | `auth.users` + `profiles` | `billing.accounts` |

## Rules written twice

| Rule | Places |
|---|---|
| Plant missing from a login's list over 50 min → gone | `plant_users_upsert` (0252:229), `billing.login_seen` (0246:401), `share_sync` (0247:520) |
| May this user add a login | `link-sunsynk:69-74`, `link_login_allowed` (0252:135), `billing.link_login` (0242:173) |
| Outbox lease, retry, 429, Resend errors | `billing.outbox_*` + `outboxPass`; `msg_email_*` + `msgEmailPass` |
| 60-day walk, newest first, 3 tries a day | `backfillPlant` (`recover:344`); `runFetch` + `billing.history_step` (`recover:529`, 0246:756) |
| Grid present means volts over 100 | `_shared/poller.ts:136`, `q_grid_present` (0055), `rollup_partition` (0266:108) |
| Push address allow-list | `push_subs_endpoint_ok` (0194), `notify:357` |

## Second brand and 1,000 plants

Covered already: brand adapter, long single runs, shared plants (SOLAR-647); shared login in one
shard, 2,000-plant list cap (SOLAR-649); minute table partitions (SOLAR-653); always-on reader at
~300 logins (SOLAR-663); delete waiting on the rollup lock (SOLAR-659).

Not covered by those tickets:

1. **Plant id is the vendor's id.** See Plants 1. Needs an own plant id before brand two, and gets
   harder with every row stored. SOLAR-647 talks about a common data interface, not the key.
2. **Login stored twice.** A second brand would add its fields to both tables.
3. **One-cloud alert state.** `email_system_state.sunsynk_down` and `sunsynk_calls` assume one
   vendor cloud; one brand's outage would mute the other's alerts (0174:126).
4. **Billing clock loops.** `outbox_sweep` every minute over every account, `delete_due` and
   `billing.alerts` every 5 minutes over every plant. Fine at 100 accounts; at a few thousand each
   run does thousands of `account_status`/`plant_state` calls.
5. **`agg_minute_rollup`** one statement (0072:57); 0266 fixed only `readings`/`strings`. Partly SOLAR-653.

## What to untangle first

| # | Job | Size | Fixes | Strongest case against |
|---|---|---|---|---|
| 1 | Revoke `api_link_disconnect` from `authenticated` | XS | Owner can't leave a half-removed login behind | None real; check no screen calls it (none does) |
| 2 | Schema snapshot in the repo (`supabase db dump --schema-only`, checked in CI); stop editing live functions by text replace (0252:108, 0256:24,122,151, 0261:365) | S | Anyone can read what runs; every later job gets cheaper | One more file to keep fresh; no owner-visible gain |
| 3 | One home for logins and plant lists: fold `sunsynk_accounts` + `plant_users` into `billing.logins` / `login_plants` (or move both out of `billing` into a `logins` schema) | L | Login status trigger, dual writes, three "gone" rules, lock-order risk, need-a-hand check | Touches almost every function; nothing visible to owners changes |
| 4 | Own plant id, mapped from `(brand, external_id)` | L | Brand two can't collide with SunSynk plants | Only needed when brand two is real; SunSynk ids can stay as the own ids, so the cost is mostly new code paths, not a data move |
| 5 | One 60-day import engine (`history_fetches`), old bookmarks retired; History owns its queue, Billing only says yes/no | M | Two engines, progress and history-ready mail for switches and restarts, hard-coded URL in 0235 | `history_fetches` does not yet do the temperature walk; gap recovery must keep working |
| 6 | `billing.outbox` into `msg.outbox`; Billing writes "send this", Messages owns retry and history | M | Her one-queue model; one retry stack, not two | Billing mail works and is tested; moving receipts and dunning risks double or lost mail for no owner-visible gain |
| 7 | Each part supplies its own "delete this account's data" step; `api_account_delete` calls them | M | Delete stops knowing five parts' tables | One function is easy to read and is one transaction today |
| 8 | Move the poller's side jobs out (plant sync, share retry, detection, alert step) | M | The minute read does one thing; SOLAR-663's worker gets simpler | Doing them inline saves calls and keeps them in step with the read |
| 9 | Billing clock loops set-based or hourly; `agg_minute_rollup` sliced like 0266 | S-M | Cliffs before 1,000 plants | Not needed until hundreds of accounts |

Left as is on purpose: Supabase Auth sending sign-in mail (it owns the links and tokens), and
`error-alert` sending straight to Resend (an alarm must not depend on the queue it may be warning
about). Both are fine outside the one-queue model; write that down so nobody "fixes" them.

## Where reviewers disagree

| Point | Own | Neon | Astra | Fable |
|---|---|---|---|---|
| Accounts | 6 | 5 | 7 | 6 |
| Data logins | 4 | 3 | 6 | 5 |
| Plants | 4 | 4 | 5 | 4 |
| Reading | 7 | 6 | 7 | 7 |
| History | 4 | 4 | 7 | 5 |
| Billing | 7 / 5 | 7 | 8 (payments) | 8 |
| Messages | 5 | 5 | 7 | 6 |
| First to untangle | logins | logins | plant id | schema snapshot, then dead switch code |

- **History.** Astra scored it 7 for 0266. Neon and I scored 4 for the two import engines; Astra saw
  the split as "progress spans plant bookmarks and billing leases" but not as two engines.
- **First job.** Astra puts the own plant id first; Neon and I put the doubled login and plant tables
  first, because they cause the most tangled joins today. Neon would do the plant id last, only when
  brand two is committed.
- **List-Unsubscribe.** Neon called its absence on alert mail a bug. It is a recorded decision
  (`_shared/email.ts:8`). Dropped.
- **`api_link_disconnect`.** Neon called it a security bypass. It checks the caller owns the login,
  so it is a consistency hole on the owner's own data, not a way into anyone else's.
- **need_a_hand for share-only users.** Neon: the guard checks `sunsynk_accounts`, so a user who only
  claimed a shared plant may still get "need a hand" (0263:81). Plausible; not reproduced.
- **Fable's first job** is different from all three: put a schema snapshot in the repo and stop
  text-replace edits of live functions, because no file shows what runs today. Neon raised the same
  problem under framing. Added to the list below as item 2.
- **Fable's own findings** not raised by others, checked: `poll_jobs_v2` still falls back to the
  dropped `poll_jobs` behind `is_live()` (0246:151-154); "our fault or SunSynk's" is decided by a
  pattern on error text and feeds the SunSynk-down alert (`_shared/poller.ts:90,107`); alert start
  time written by both `billing.readings_start` and `plant_start_fill` (0256:60, 0205:122); job health
  kept in both `billing.job_heartbeats` and `private.job_checks`; `Africa/Johannesburg` default in
  ~33 live SQL places; billing doors take a text command and loose JSON, so a wrong name fails only
  at run time (0254:1176-1211).
- **Fable on `sync-plant-energy`:** one call for the fleet, ~3 SunSynk calls a plant, 110 s budget;
  estimate 40-70 plants a night, so weeks per round at 1,000. Not measured. Part of SOLAR-647
  ("long single runs").
- **Alert detection.** Fable and Neon both say detection (`email_poll_step`, `email_sweep`) is its own
  part filed under Messages. Agreed; it reads readings and writes login rows (0231:39-41).

## Framing

- The seven parts are not seven boxes. The code is three generations side by side: the old
  `public`/`private` tables, SOLAR-641's `billing` schema, and SOLAR-645's `msg` schema. Each rebuild
  is good inside and left the one before half alive. Most tangled joins are where two generations
  hold the same fact. (Neon, agreed.)
- "1,000 plants" and "second brand" are different jobs. The first is throughput and can wait for
  the SOLAR-663 trigger. The second is the plant key, which gets harder with every row stored. (Neon, Astra.)
- "1,000 plants" needs a shape: 1,000 homes on their own logins and 1,000 plants behind the share
  login stress different code. (Astra.)
- Patching live functions with `pg_get_functiondef()` + `replace()` (0252:108, 0256:24, 0261:365)
  means no single file shows what runs. Finding the live body of a function takes a script. (Neon.)
