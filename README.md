# SunSynk Live Dashboard

A dashboard for a **SunSynk Connect** solar install: live solar generation, battery
state of charge, grid import/export, home load, an energy-flow diagram, day charts,
and longer-run trends across **every inverter on the account**.

It also keeps its own minute-by-minute history, which is the point of it. SunSynk's
cloud drops detail after a week or two; this logs every minute permanently, so the
trends, integrity checks and battery-health views have something real to work from.

> Two inverters? No setup needed — every inverter on the account is discovered
> automatically and shown as a combined summary plus a card each.

---

## How it works

The backend runs on Supabase. Nothing needs to stay switched on at home.

```
                    ┌──────────────── Supabase ────────────────┐
                    │                                          │
   pg_cron ─ 1/min ─┼─> poll ──────────────> api.sunsynk.net   │
   pg_cron ─ 6h ────┼─> recover ───────────> api.sunsynk.net   │
   pg_cron ─ daily ─┼─> sync-plant-energy ─> api.sunsynk.net   │
   pg_cron ─ 6h ────┼─> forecast ──────────> api.open-meteo.com│
                    │        │                                 │
                    │        v                                 │
                    │    Postgres  <── api_* functions ────────┼──> browser
                    │    (RLS, authenticated-only)             │    (GitHub Pages)
                    └──────────────────────────────────────────┘
```

- **poll** — every minute, reads all five realtime endpoints per inverter and stores
  per-inverter readings, per-string PV, and a summed row on the aggregate spine.
- **recover** — every 6 hours, backfills minutes the logger missed from SunSynk's
  cloud, calibrated against that day's own data. Tagged `source='plantfeed'` and
  fully reversible.
- **sync-plant-energy** — daily, caches plant-level kWh totals that reach back to
  commissioning, which predate the local history and can't be derived from it.
- **forecast** — every 6 hours, pulls three days of plane-of-array irradiance from
  Open-Meteo, which is what the Live tab's solar outlook and the chart's forward line
  are drawn from. Weekly it also refits the two constants that turn W/m² into watts for
  *this* array, against months of our own logged production — so the forecast calibrates
  itself rather than trusting a datasheet. No API key: Open-Meteo needs none.

**The browser never talks to SunSynk.** It reads Postgres through `api_*` functions,
nothing else. SunSynk credentials exist only as Edge Function secrets; the access
token lives in a `private` schema that PostgREST does not expose, reachable only via
`SECURITY DEFINER` accessors granted to `service_role`.

The publishable key ships in this repo on purpose — it grants nothing by itself.
Every table has RLS and every `api_*` function is granted to `authenticated` alone,
so reading anything requires a signed-in session.

---

## Local development

Requires [Docker](https://docs.docker.com/get-docker/), the
[Supabase CLI](https://supabase.com/docs/guides/cli), and Node 18+.

```bash
supabase start                 # local Postgres + auth + Edge Functions
supabase db reset              # apply migrations and seed a dev user
npx serve public -l 3003       # serve the frontend
```

Open **http://localhost:3003** and sign in with `dev@local.test` / `devpassword123`
(created by `supabase/seed.sql`; local only).

`public/config.js` switches on hostname, so a page served from localhost talks to the
local stack automatically and production talks to production.

To run an Edge Function locally, put your SunSynk credentials in
`supabase/.env.local` (gitignored) and:

```bash
supabase functions serve poll --env-file supabase/.env.local --no-verify-jwt
curl -X POST http://127.0.0.1:55321/functions/v1/poll -H "Authorization: Bearer <service key>"
```

`forecast` needs no credentials at all, so it runs locally as-is:

```bash
supabase functions serve forecast --no-verify-jwt
curl -X POST 'http://127.0.0.1:55321/functions/v1/forecast'                # fetch 3 days
curl -X POST 'http://127.0.0.1:55321/functions/v1/forecast?mode=calibrate' # refit the constants
```

`pg_cron` is not enabled locally, so nothing runs on a schedule — invoke functions by
hand. Ports are shifted to the 553xx range so this can run alongside another local
Supabase project.

### Importing existing history

`scripts/etl-sqlite-to-postgres.js` moves a legacy SQLite log into Postgres. It's
re-runnable — every table stages into a temp table and upserts, so running it again
only banks the delta.

```bash
node scripts/etl-sqlite-to-postgres.js --dry-run     # counts only
node scripts/etl-sqlite-to-postgres.js               # -> local stack
node scripts/etl-sqlite-to-postgres.js --url='postgresql://...'   # -> remote
```

---

## Deploying

```bash
supabase link --project-ref <ref>
supabase db push                                   # migrations
supabase secrets set --env-file supabase/.env.local
supabase functions deploy poll recover sync-plant-energy forecast
```

Then, once, in the dashboard:

1. **Database → Extensions** — enable `pg_cron` and `pg_net`
2. **SQL editor** — `select vault.create_secret('<secret key>', 'service_role_key');`
3. **Authentication → Users** — add the user you'll sign in as

`supabase/migrations/0009_schedule.sql` registers the cron jobs. It no-ops anywhere
`pg_cron` isn't enabled, which is how it stays harmless on the local stack.

The frontend deploys itself: pushing to `main` triggers `.github/workflows/pages.yml`,
which publishes `public/` to GitHub Pages. There's no build step — the `.jsx` is
transpiled in the browser by Babel standalone.

---

## Configuration

Solar-model constants live in the `app_config` table, not in code:

| key | meaning |
|---|---|
| `LAT` | latitude for sun geometry |
| `LON` | longitude — only the weather forecast needs it |
| `PANEL_TILT` | degrees from horizontal |
| `PANEL_AZIMUTH` | compass degrees from north |
| `SOLAR_DNI_BASE` | clear-sky beam attenuation |
| `SYSTEM_KWP` | nameplate kWp, the calibration ceiling |
| `SOLAR_CAL_PERCENTILE` | calibration percentile |
| `SOLAR_CAL_CAP_MULT` | ceiling as a multiple of nameplate |

These drive the clear-sky "potential" curve, and `PANEL_TILT` / `PANEL_AZIMUTH` are sent
to Open-Meteo so the forecast is for this roof rather than a flat one. Getting
`PANEL_AZIMUTH` wrong visibly skews both, so they're data rather than constants.

Battery sign convention is the `BATTERY_POSITIVE_MEANS` Edge Function secret
(`charging` or `discharging`) — flip it if charge/discharge reads backwards versus
the SunSynk app. Storage is normalised to `+ = charging` regardless.

---

## Legacy

`server.js` and `db.js` are the original single-process version: Express serving the
UI and API, polling into a local SQLite file. It's kept because it's the reference
the Supabase port was verified against — every endpoint was diffed against it — and
because it still reads a legacy `data/sunsynk.db`. It is no longer the way this runs.

Two things were deliberately not ported:

- **the `raw` table** — 46 MB of the old 96 MB file, gzipped API payloads with no
  consumer, and a place account identifiers could hide
- **`/api/debug/:sn`** — proxies live to SunSynk, so it must never be publicly callable

---

Unofficial project — not affiliated with or endorsed by SunSynk. The endpoints are
the ones SunSynk Connect's own web app uses and may change without notice.
