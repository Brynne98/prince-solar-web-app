# Messages rebuild (SOLAR-645)

Plan only. Nothing here is built. Written 2026-11-24 from the code on branch
`t3/messages-outbox-rebuild` (base `fb49a55`), checked by the council (Neon, Sol) the same day.
`M/` = `supabase/migrations/`, `F/` = `supabase/functions/`.

## 1. What sends today

### One table does three jobs

`public.email_queue` (`M/0102:56`, push columns `M/0124`) is at the same time:

1. the email queue (`status`, `tries`, `due_at`, `batch_key`, `priority`),
2. the push queue (`pushed_at`, `push_skip`),
3. the alert list in the app: `api_alerts` (latest `M/0232:256`) and `api_notifications` (`M/0252:331`) read it, with `read_at`.

Other readers: `link-sunsynk` (`F/link-sunsynk/index.ts:91`, need-a-hand analytics), the job-check backlog count (`M/0234:73`, counts `status='queued'`), and many `scripts/sql/*.sql` tests.

### Messages

| Kind | Channel | Made by | Recipient check | Words |
|---|---|---|---|---|
| grid, battery hot, bank drift, string dead, logger stale (each with "back"; battery-hot and bank-drift "back" send no email, `F/notify/index.ts:330`) | email + push + alert list | poll step: `email_poll_step` `M/0231`, `email_plant_apply` `M/0164:43`, fan-out `email_enqueue_plant` `M/0102:100` | queue: `email_skip_unchosen` `M/0252:88`; send: `email_claim` `M/0247:774` (email), `push_claim` `M/0232:197` (push) | email `_shared/email.ts:643`; push + list `alert_text` `M/0233:15`, `push_text` `M/0229` |
| no readings (logger_stale from sweep) | same | `email_sweep` `M/0174:55`, 30 min after last reading | same | same |
| SunSynk down / back | email + push + list | `email_sweep` `M/0174:105`, more than half the logins failing | queued on the owner's **oldest** plant (`M/0174:109`); dropped if that plant has no seat | `email.ts:470,481`; `alert_text` |
| needs reconnect / reconnected | email + push + list | `email_on_relink` `M/0232:31`, patched `M/0252:106` (seat filter added) | first plant with a seat; other plants' rows inserted `skipped`; no switch | `email.ts:706`; `alert_text` |
| share down/back, share removed, plant off login | email | `M/0232:40`, `M/0247:538`, `M/0252:232` | as above | `loginEvent` |
| welcome, need a hand (+24 h) | email | `email_on_confirm` `M/0147:11` | skipped once a plant or login exists; need-a-hand keeps going with `choose:true` while plants wait to be chosen (`M/0247:806`) | `email.ts:398,410` |
| history ready | email | `M/0217:185`, `M/0102:549` | plant live; held while history loads (`historyWaits`, `F/notify/index.ts:289`) | `historySynced` |
| week / month / year report | email | `email_sweep` 07:00 local, `private.reports_due` | `email_wanted` + `billing.report_wanted`; held while history loads (`historyPending`, `:270`) | `email.ts:539` |
| account deleted | email | `api_account_delete` `M/0252:385` | none; user row is gone at send, address kept on the row | `accountDeleted` (`:388`) |
| feedback | email to hello@ | `M/0179:51` | none; screenshot scrubbed after send (`M/0179:59`) | `email.ts` |
| bill mail failed, free week set-up, old `bill_*` | email | `M/0130:1085`, `free_week_mail` | dead since `M/0252` | |

Billing (15 kinds, `M/0254:31`) already runs on `billing.outbox` (`M/0244:158`, `M/0247:1093`, `M/0254`), words in `_shared/text.ts:565`.

### How the old queue sends

- **Email:** `email_claim` takes 100 rows `for update skip locked`, marks them `sending`, `tries+1`. notify sends them as Resend **batch** calls (up to 100 emails a call, `F/notify/index.ts:544`), one call per 550 ms (`:48`). Idempotency key is a hash of the row ids, kept for the retry (`:541`). 8 tries, back-off to 1 h. A row stuck in `sending` 10 min goes back to `queued`.
- **Billing outbox:** one Resend call per email, key `ob-<id>` (`_shared/outbox.ts:6`).
- **Push:** `push_claim(200)` sets `pushed_at` on every row **before** the send (`M/0232:234`). A failed send is never tried again (`F/notify/index.ts:593`). Rows over 1 h old are skipped.
- **One run for all:** cron `email-notify` every minute, 55 s (`M/0092:375`, re-registered `M/0181:160`). Order: sweep (`:674`) → old email loop to 40 s (`:683`) → billing outbox to 45 s (`:763`) → push to 50 s (`:768`).
- `alerts-due` has no caller and sends nothing. `job-check` sends PostHog events only.

### Unsubscribe and quiet hours

- Email switches: `public.email_prefs`, checked at send in `email_claim` via `email_wanted`. Push switches: `public.push_prefs`, `push_wanted` (5 switches).
- needs reconnect / reconnected skip both switches on purpose.
- **Quiet hours do not exist** anywhere in the code.

### Ticket points, checked

| # | Point | Result |
|---|---|---|
| 1 | push lost on failure | **True.** `M/0232:234` marks first; no retry |
| 2 | one clock | **True.** push gets what is left after 50 s; a slow Resend or many refusals (each split in half) eat the 40 s |
| 3 | push ignores plan | **True.** `M/0232:210` checks `plant_users`; only the queue-time trigger checks seats |
| 4 | SunSynk down lost | **True** for `sunsynk_down` only. needs reconnect has the seat filter since `M/0252:106` |
| 5 | words in three places | **True.** email in TS; push and list in SQL |
| 6 | no-readings grace not reset | **True.** `started_at` is set only by `private.plant_start_fill` (`M/0205`); nothing from 0206 on calls it. Seats also stay open when a plan ends (`M/0246:604,659`), so the reset must key on readings starting again, not on a seat opening |

## 2. Design

### Shape

Keep the alert list. Split "what happened" from "send it". Split workers by **channel**, not by urgency.

```
poll / sweep / triggers ──> email_queue as the event log  (one row per owner per thing; alert list reads it)
                               │  same transaction, only for kinds routed to the outbox
                               ▼
                           msg.outbox   (one row per event per channel)
                           msg.push_sends (one row per outbox push row per device)
                               │
        ┌──────────────────────┴──────────────────────┐
  notify-email (cron each minute)               notify-push (cron each minute)
  one Resend worker, drains in order:           own clock, no Resend
  urgent alerts → billing → bulk
  batches for bulk, 429 Retry-After honoured
  owns email_sweep and billing sweep
```

- **Event log.** `email_queue` keeps its rows, `read_at`, `pair_key`, `data`. Rows routed to the outbox get `status='outbox'` so the old claim, the job-check backlog count and `api_*` readers see no stuck `queued` rows. A rename can come last or never.
- **`msg.outbox`** copies `billing.outbox`: `dedupe_key` unique (`<event id>:<channel>`), `not_before`, `expires_at`, `status` (queued, sent, dropped, failed), `claimed_until`, `tries`, `drop_reason`, `last_error`, `lane` (urgent, bulk), `channel` (email, push; later telegram), `to_email` captured at insert for kinds whose user is gone (account deleted).
- **`msg.push_sends`**: one row per device, leased with a claim token, acknowledged per device. Retry 429, 5xx and network errors only, inside the event's 1 h expiry; 404/410 removes the device. A lost reply can still show twice; accepted.
- **One email worker.** Resend has one rate per account. Three workers would each pace alone and collide. One worker drains urgent, then billing, then bulk; bulk keeps batch calls with a stored key, as today. Push gets its own cron because it never touches Resend. This fixes point 2. `call_fn` cuts `?…` from the path (`M/0181:34`), so the two workers are two function names, not one function with a parameter.
- **Guard at send time**, per kind (like `billing.outbox_guard` `M/0254:966`):
  - plant not chosen (open `billing.seats`, same test as `account_state`), plant not live, switch off (`email_wanted` / `push_wanted`), expired (alerts 1 h, reports 2 days);
  - kinds that skip parts of this keep doing so: reconnect and share-removed skip switches; account deleted and feedback skip user checks and use the captured address;
  - **down/back:** a "back" waits (not dropped) while its "down" on the same channel is queued or leased, on either path; it is dropped only if its "down" was dropped or failed; a "down" is never dropped because its "back" came in. Per device for push: a "back" goes only to devices that took the "down".
- **One set of words.** Alert kinds move into `mail()` in `_shared/text.ts`, plus a `push()` there. The alert list text: decision A in §5.

### Order, and what ships alone

| Step | What | Fixes | Alone? | Size |
|---|---|---|---|---|
| 1 | XS fixes on the old path: seat check in `push_claim`; `sunsynk_down` on the first chosen plant of a failing login; reset `started_at` when a plant's readings start again (plan restart, seat chosen, grant) | 3, 4, 6 | yes | S |
| 2 | two workers: `notify-email` (urgent → billing → bulk, one Resend pace, 429 back-off, owns the sweeps) and `notify-push`; job-check watches both | 2 | yes | S |
| 3 | `msg.kinds` (route per kind and channel), `msg.outbox`, `msg.push_sends`, guard, take/done; flip **push** for all alert kinds | 1 | yes | M |
| 4 | flip alert **email** kinds (urgent lane) | aim | after 3 | S |
| 5 | flip bulk kinds; port their hooks first: history holds and resync, need-a-hand analytics (two events, plus `link-sunsynk:91`), feedback scrub, account-deleted address | aim | after 3 | M |
| 6 | words: one shared JS file for alert list, push and email; SQL `alert_text`, `push_text` removed | 5 | after 4 | M |
| 7 | remove old paths: `email_claim`, `push_claim`, old email loop, dead `bill_*` code, `alerts-due` | | after a week clean | S |

Push goes first in the outbox because it is the send that is lost today (ticket point 1) and has no hooks to port. A cheap retry on `email_queue` is skipped: it would be thrown away at step 3.

### Switching without double or lost sends

- **Route is fixed at insert.** `msg.kinds(kind, channel, route)` says where each kind goes. Existing rows default to `old`. The insert trigger reads it; for `outbox` it sets `status='outbox'` and adds outbox rows, only for rows that would have been `queued` (reconnect's `skipped` rows for plants 2..N get none). `email_claim` and `push_claim` take only `old` rows, in their claim and in their stuck-row reset.
- Rows queued before a flip finish on the old path. Nothing is decided again at claim time.
- Flip a kind only with no `sending` rows of that kind, between worker runs.
- Flipping back is the same update, for new rows only. The down/back guard looks on both paths, so a "down" on old and a "back" on outbox still pair.
- Email idempotency key for outbox rows: `ms-<outbox id>`; for bulk batches, a stored batch key, as today.

### Proof for each step

- SQL tests in the style of `scripts/sql/billing-state-tests.sql`: each guard rule, a flip with rows in flight, a cross-path down/back pair, a lost reply, a flip back.
- Deno tests for take/done and the 409/429 cases, as `_shared/links_test.ts`.
- Monitoring: per-worker heartbeat, oldest queued age per lane, expired and 429 counts in job-check.

## 3. Risks

| Risk | Where | Guard |
|---|---|---|
| Double email at a flip | a row taken by both paths | route fixed at insert; both claims filter on route |
| Duplicate reconnect emails | reconnect inserts one row per plant | outbox rows only for `queued` rows |
| Double push on retry | no push idempotency | per-device sends; retry only 429/5xx/network |
| Lost send at a flip | a claim-time check skipping old rows | no claim-time routing; old path drains its own rows |
| "Back" never sent | back dropped while down is in flight | back waits; dropped only if down dropped/failed; pairs across paths |
| Lost send in a burst | one 55 s run | push on its own worker; urgent first in the email worker |
| Resend rate exceeded | several senders | one email worker; 429 `Retry-After`. `error-alert` also calls Resend (`F/error-alert/index.ts:35`); low volume, leave it |
| False backlog alarm | moved rows left `queued` | `status='outbox'` |
| Hooks lost on move | history holds, analytics, feedback scrub, account-deleted address | step 5 ports them before the flip |
| Unsubscribe ignored | switch read at queue time only | guard reads switches at send time; List-Unsubscribe on bulk, as billing |
| Reconnect blocked by a switch | guard too strict | per-kind guard; no-switch list kept |
| Alert list breaks | event rows change | rows, `read_at`, `pair_key` kept; `api_alerts` unchanged until step 6 |
| Migration numbers clash | SOLAR-650 also adds migrations | build after SOLAR-650 merges, or take numbers then |
| Quiet hours | none exist | decided: none; owners use device settings |

## 4. Follow-ons that fit (not built here)

- **SOLAR-474, day-7 no-plant reminder:** a new bulk kind. `email_on_confirm` adds the event with `not_before = confirm + 7 d`; guard drops it if any SunSynk login exists. After step 5.
- **SOLAR-311, battery level alerts:** new urgent kinds `batt_low` / `batt_low_back` per level; per-plant level state like `plant_alert_state`. Telegram = a new `channel` value, its own worker and a `telegram_links` table; the outbox itself needs no change. After step 4.
- **SOLAR-315, loadshedding warning:** event with `not_before = slot − lead`, `expires_at = slot start`; battery % read at send time, so it is current. After step 4, and after the EskomSePush terms check.

## 5. Decisions (Brynne, 2026-11-24)

- Plan approved, all steps 1–7.
- **A. One set of words everywhere.** Alert list, push and email come from one shared JS file, read by both the edge functions and the web app. `alert_text` and `push_text` in SQL go. Reason: wording drifts when it lives in more than one place.
- **B. Quiet hours: none.** Owners set notification settings on their own devices.

## 6. Council (Neon, Sol), 2026-11-24

Both checked against the code; what held is in the plan above.

- **Both:** three Resend lanes collide; down/back guard dropped real "back" messages; push retry must be per device; hooks and readers missed; monitoring and tests missing.
- **Neon only:** old email sends in batches of 100 (the first draft said one per call); push belongs on its own worker; moved rows must leave `queued`; reconnect's `skipped` rows; `call_fn` cuts the lane parameter; skip a throwaway push retry on `email_queue`.
- **Sol only:** account-deleted needs a captured address; need-a-hand choose-plants path; `sunsynk_down` must pick a plant on a failing login.
- **Rejected:** Neon said `M/0252:107` dropped the seat filter for reconnect. It did not: the same patch adds an `exists (… billing.seats …)` filter (`M/0252:112`).
