# Solar alerts — handoff

Getting solar alerts onto a phone. Written 18 Aug 2026, spanning two repos:
`prince-solar-web-app` (this one, then named `sunsynk-dashboard`) and
`prince-todo-app`.

**The headline:** don't build a notification channel. `prince-todo-app` already has one,
already talks to this project's API, and already solves the hard parts.

---

## 1. Why the todo app and not ntfy/Telegram

The obvious plan was a new Edge Function here posting to ntfy. That was wrong, because
`prince-todo-app` is **already a SunSynk client**:

| What it already has | Where |
|---|---|
| SunSynk API client + auth | `app/src/sunsynk/api.ts`, `SunsynkProvider.tsx` |
| A Solar tab polling every 60 s | same |
| A home-screen solar widget | `app/src/widget/solar.ts` |
| A half-hourly silent-push wake | widget wake, migration 0061 (per its comments) |
| Expo push delivery | `location-alerts`, `item-notifications`, `daily-digest` |
| Dead-token handling | `clear_invalid_push_token`, shared by all three senders |
| A batched-digest pattern | `daily-digest` |

A second channel would mean a second thing to provision, a second thing to mute, and
duplicated delivery plumbing — all to reach the same phone.

---

## 2. The pattern to copy

`prince-todo-app/supabase/functions/location-alerts/index.ts` is the closest analogue
and its header states the convention plainly:

> 1. ask Postgres what is due via `location_alerts_due()`. **All the detection lives
>    there, next to the pings it reads**; this file only decides how a thing is worded
>    and puts it on the wire.
> 2. push each via Expo. On `DeviceNotRegistered`, null the token via
>    `clear_invalid_push_token`.
> 3. stamp `location_alerts_sent` so the same event never fires twice.

Two things to take from it:

**Detection in SQL, delivery in the function.** Not thresholds in TypeScript.

**Dedup is an `event_key` + a unique index**, not a boolean state row:

```sql
-- prince-todo-app, migration 0048
create unique index location_alerts_sent_once
  on public.location_alerts_sent (watcher_id, subject_id, kind, event_key);
```

That is better than the `alert_state` table originally sketched here. An `event_key`
naturally encodes *which* occurrence fired ("soc_low:2026-08-18T19:40"), so a repeat of
the same event is a duplicate-key no-op rather than something needing a state machine.
Reuse the idea; do not invent a parallel one.

`battery_low` is already an alert kind there (phone battery), so the wording and
severity conventions exist to follow.

---

## 3. Proposed split

```
prince-solar-web-app                   prince-todo-app
────────────────────                   ───────────────
api_alerts_due()   ──── called by ───> solar-alerts (Edge Function)
  detection, thresholds,                 wording + Expo push
  debounce, event_key                    + stamps solar_alerts_sent
```

**Detection stays here** because it needs `agg_minute`, `readings`, and the calibration
— none of which the todo app has. **Delivery stays there** because that is where the
push tokens, the dead-token handling and the digest live.

This mirrors how the widget already works: this project owns the data, the todo app owns
the surface.

### The contract

One RPC here, returning rows the other side can send without further thought:

```sql
create or replace function public.api_alerts_due()
returns table (
  kind        text,          -- 'logger_stale' | 'bank_drift' | 'batt_hot' | ...
  event_key   text,          -- unique per occurrence; the dedup key
  severity    text,          -- 'urgent' | 'digest'
  title       text,
  body        text,
  value       double precision
)
```

Grant `execute` to `service_role` only. The todo app calls it with this project's
**secret key** (`sb_secret_…`, stored as an Edge Function secret there).

> Note: this project's **legacy JWT keys are disabled** (since 2026-08-05). Anything
> using the old `anon` / `service_role` JWTs gets `401 Legacy API keys are disabled`.
> Use the new-style publishable/secret keys.

---

## 4. Rules to implement

| Kind | Source | Threshold | Severity |
|---|---|---|---|
| `logger_stale` | `api_health` | `stale = true` (>5 min old) | urgent |
| `bank_drift` | `api_balance` | `status = 'drifting'` | urgent |
| `batt_hot` | `api_balance.tempHot` | already computed | urgent |
| `soc_overnight` | Live-tab runtime maths | won't reach sunrise at current draw | urgent |
| `grid_down` / `grid_back` | `readings.grid_volt_v` | **blocked — see §6** | urgent |
| `string_dead` | `strings` | one string ~0 W at midday while its sibling produces | digest |

`api_health` and `api_balance` already exist and are granted to `service_role`.
`api_balance` also already debounces: a bank spread must hold ~10 continuous minutes
before it flags, and one dip resets it. Do not re-implement that.

### Debounce and hysteresis

- **Debounce** — a condition must hold for N consecutive minutes before it becomes due.
  `api_balance` shows the SQL shape (MIN across a window).
- **Hysteresis** — fire below 20% SoC, re-arm only above 30%. Without the gap it flaps
  at the boundary all evening.
- **Re-notify** — decide whether a still-active alert repeats after some hours. The
  `event_key` scheme makes this an explicit choice rather than an accident.

---

## 5. First slice

1. `api_alerts_due()` here with **two** kinds only: `logger_stale` and `bank_drift`.
2. `solar-alerts` Edge Function in the todo app, cloned from `location-alerts`.
3. `solar_alerts_sent` table + unique index there.
4. `pg_cron` every 5 minutes.

That proves a notification reaches the phone and that a flapping condition does not
spam. Each further rule is then a few lines of SQL.

**Why `logger_stale` first:** `.github/workflows/health.yml` already emails on a stale
logger, but it is a GitHub cron — best-effort, so "you'll know within the hour". This
would make it five minutes. `bank_drift` is currently unmonitored entirely:
`balance-watch.sh` was the prototype and it still points at `localhost:3002`, the retired
Express server.

---

## 6. Blocked: grid alerts

`grid_down` / `grid_back` cannot be built yet.

`grid_w` and `grid_freq_hz` cannot tell a blackout from a quiet solar afternoon — both
read zero. Migration `0015` started recording `readings.grid_volt_v` and
`grid_relay_status` on 18 Aug 2026 to fix this, but **only the relay-closed state has
ever been observed** (~240 V, 50 Hz). What voltage does when the relay opens is unknown.

See `FEATURES.md` → "Open question — grid presence" for the query that settles it and
what each outcome means. Until then, leave these two kinds out.

---

## 7. Open questions

Things not verified — check before building:

- **Push token model.** `location-alerts` uses `watcher_id` / `subject_id` (person to
  person). Solar alerts have no subject. Do they go to both people, or is there a
  per-user preference table to hang them off?
- **Cross-project auth.** Confirm the todo app's Edge Functions can hold a second
  project's secret key, and decide where it is set.
- **Scheduling.** A new 5-minute `pg_cron` job, or ride the existing half-hourly silent
  wake? Half-hourly is too slow for `logger_stale`; the wake may still be right for the
  digest.
- **Quiet hours.** Does the todo app already have a do-not-disturb window worth
  respecting? `daily-digest` implies a preferred send time exists.
- **Where this doc should live.** It is in this repo because the detection side is here,
  but most of the work lands in `prince-todo-app`.
