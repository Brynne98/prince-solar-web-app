# SunSynk Connect API — Reference

What the **SunSynk Connect cloud API** (`https://api.sunsynk.net`) exposes, as
observed against this account's hardware (two inverters, single battery bank each).
This is the unofficial web/app API — the same endpoints the SunSynk Connect web
app uses — *not* the official signed OpenAPI at `openapi.sunsynk.net`.

> Field names and shapes vary by firmware. Values below are real samples captured
> on 2026-05-29; treat them as illustrative, not guaranteed.

---

## Authentication

> ⚠️ The old plaintext login (`POST /oauth/token`) was removed by SunSynk and now
> 404s. The current flow (implemented in
> `supabase/functions/_shared/sunsynk.ts` → `login()`) is:

1. **Fetch RSA public key**
   `GET /anonymous/publicKey?nonce={ms}&source=sunsynk&sign={md5}`
   where `sign = md5("nonce={nonce}&source=sunsynkPOWER_VIEW")`.
   Returns base64 DER (SPKI) public key in `data`.
2. **RSA-encrypt the password** with that key using **PKCS#1 v1.5** padding, then base64.
3. **Log in**
   `POST /oauth/token/new` with JSON:
   ```json
   {
     "username": "...",
     "password": "<rsa-encrypted, base64>",
     "grant_type": "password",
     "client_id": "csp-web",
     "source": "sunsynk",
     "nonce": <ms>,
     "sign": "md5(\"nonce={nonce}&source=sunsynk\" + rawKey.slice(0,10))"
   }
   ```
   Returns `data.access_token` (+ `refresh_token`, `expires_in`). Pass the token
   as `Authorization: Bearer <token>` on all subsequent calls; on `401`, re-login.

---

## This app's read API (Postgres functions)

Every endpoint is a Postgres function called over PostgREST:

```
POST /rest/v1/rpc/<name>
  apikey: <publishable key>
  Authorization: Bearer <user session JWT>
  {"p_days": 14}
```

EXECUTE is granted to `authenticated` only, so a signed-in session is required —
the publishable key alone gets `42501 permission denied`. The JSON shapes are
unchanged from the original Express routes, which is why `public/data.jsx` only
needed its transport swapped.

| RPC | Params | Returns |
|-----|--------|---------|
| `api_overview` | — | Aggregated + per-inverter snapshot from the newest logged minute (see below) |
| `api_history` | `p_date` | Per-plant 5-min day series (defaults to today), re-gridded onto all 288 buckets. `value: null` marks buckets with no data anywhere, `est: true` marks cloud-recovered buckets (`source='plantfeed'`), `gapMinutes` counts truly-missing minutes, `recoveredMinutes` counts recovered ones |
| `api_history_earliest` | — | `{ earliest }` — first day with data (≈ commission date); lower bound for the day picker |
| `api_energy` | `p_period` | `week` / `month` / `year` / `lifetime` kWh rows from the cached plant totals |
| `api_db_stats` | — | History-log health: rows, distinct days, first/last timestamps |
| `api_trends_by_hour` | `p_days` | Avg power per hour-of-day from complete days only: `pv_w / load_w / baseline_load_w / grid_w / soc / surplus_w / spare_w` |
| `api_trends_daily` | `p_days` | Last N days of plant kWh totals. Previous days come from the `plant_energy` cache; **today is computed live from `agg_minute`**, since the cache only refreshes on the daily cron (see migration 0013 for the source-mixing caveat) |
| `api_trends_monthly` | — | Every month on record, tagged year + month |
| `api_trends_compare` | — | Period-over-period totals, each compared against the same elapsed slice of the previous period |
| `api_trends_segments` | `p_days` | Avg power per day-segment with load split by source (solar / battery / grid) |
| `api_trends_potential` | `p_date` | Calibrated clear-sky potential curve: `{ scaleW, points[] }` |
| `api_balance` | — | Bank desync signal (sustained 10-min SOC spread) plus battery temperature and time-at-full |
| `api_forecast` | — | Three-day solar outlook: `{ k, kDay, calibrated, samples, updatedAt, days[], points[] }`. `days[]` carries `kwh` / `peakW` / `cloud` per day, plus `remainingKwh` on today; `points[]` is today's curve on the same 5-min grid as `api_trends_potential` |

Internal `q_*` primitives (the equivalent of the old `db.js` exports) are
`service_role`-only except for the read-only ones the `api_*` wrappers call.

**Not exposed:** the old `GET /api/debug/:sn` raw passthrough. It proxies live to
SunSynk, so publishing it would let anyone burn the account's API quota. It still
exists in `server.js` for local field discovery.

Physics auditing (`integrityReport`, DATA_PIPELINE.md §9A/§9B) has no RPC — it is a
CLI concern, run with `npm run check` against a local SQLite log.

### Weather (not SunSynk)

The forecast is the one thing on the dashboard that doesn't come from SunSynk. It reads
[Open-Meteo](https://open-meteo.com) — keyless, free for non-commercial use — through the
`forecast` Edge Function, never from the browser.

| | |
|---|---|
| Forecast | `api.open-meteo.com/v1/forecast` — `forecast_days=4` |
| Archive | `archive-api.open-meteo.com/v1/archive` — historical, for calibration (trails ~3 days) |
| Variables | `global_tilted_irradiance_instant`, `shortwave_radiation_instant`, `cloud_cover`, `temperature_2m` |
| Geometry | `tilt` + `azimuth` from `app_config`, `timezone=Africa/Johannesburg` |

Two conventions to keep straight, both verified against the live API and documented at
length in `supabase/migrations/0012_solar_forecast.sql`:

- **Azimuth is 0 = south, −90 = east, +90 = west.** `PANEL_AZIMUTH` is degrees from
  *north*, so it converts as `((az − 180 + 540) mod 360) − 180` — here 340 → 160.
- **Use the `_instant` variables.** The plain ones are means over the *preceding* hour,
  which shifts the curve half an hour early and fakes an afternoon skew.

## Underlying SunSynk endpoints used (per inverter, refresh ~1×/min)

| Purpose | Endpoint |
|---------|----------|
| Inverter list | `GET /api/v1/inverters?page=1&limit=20&...` |
| PV / input | `GET /api/v1/inverter/{sn}/realtime/input` |
| AC output | `GET /api/v1/inverter/{sn}/realtime/output` |
| Grid | `GET /api/v1/inverter/grid/{sn}/realtime?sn={sn}` |
| Battery | `GET /api/v1/inverter/battery/{sn}/realtime?sn={sn}&lan=en` |
| Load | `GET /api/v1/inverter/load/{sn}/realtime?sn={sn}` |
| Day history | `GET /api/v1/plant/energy/{plantId}/day?date={YYYY-MM-DD}&id={plantId}&lan=en` |

---

## Field catalog

Legend for **Used**: ✅ shown on dashboard · ⬜ fetched/available but not displayed.

### ☀️ PV / Solar — `/realtime/input`

| Field | Unit | Meaning | Used |
|-------|------|---------|:----:|
| `pac` | W | Total PV power now | ✅ |
| `etoday` | kWh | PV generated today | ✅ |
| `etotal` | kWh | PV generated lifetime | ⬜ |
| `pvIV[]` | — | Per-string array (below) | ✅ |
| `mpptIV[]` | — | Per-MPPT array (empty on this hw) | ⬜ |
| `grid_tip_power` | W | — | ⬜ |

**`pvIV[]` per string:** `pvNo`, `vpv` (V), `ipv` (A), `ppv` (W), `todayPv` (kWh), `sn`, `time`.
→ String-level diagnostics: spot a dead/shaded string (e.g. string 1 idle at ~1 V, string 2 producing).

### 🔋 Battery — `/battery/.../realtime` (richest endpoint)

| Field | Unit | Meaning | Used |
|-------|------|---------|:----:|
| `power` | W | Battery power (magnitude) | ✅ |
| `soc` / `bmsSoc` | % | State of charge | ✅ |
| `voltage` / `bmsVolt` | V | Pack voltage | ✅ |
| `current` / `bmsCurrent` | A | Current; **sign = charge/discharge** | ✅ |
| `temp` / `bmsTemp` | °C | Pack temperature | ✅ |
| `capacity` / `correctCap` | Ah | Rated capacity (200 Ah here) | ⬜ |
| `etodayChg` / `etodayDischg` | kWh | Charged / discharged today | ⬜ |
| `emonthChg` / `emonthDischg` | kWh | This month | ⬜ |
| `eyearChg` / `eyearDischg` | kWh | This year | ⬜ |
| `etotalChg` / `etotalDischg` | kWh | Lifetime | ⬜ |
| `chargeVolt` / `dischargeVolt` | V | Target voltages | ⬜ |
| `chargeCurrentLimit` / `dischargeCurrentLimit` | A | BMS limits | ⬜ |
| `maxChargeCurrentLimit` / `maxDischargeCurrentLimit` | A | Max limits | ⬜ |
| `type`, `status`, `numberOfBatteries` | — | Battery type / state / count | ⬜ |
| `bms1Version1/2` | — | BMS firmware | ⬜ |
| `*2` fields (`current2`, `voltage2`, `soc2`, …) | — | **Second bank** — `null` = single bank | ⬜ |
| `batterySoc1`/`Current1`/`Volt1`/`Power1`/`Temp1` | — | Per-pack breakdown | ⬜ |
| `batt1Factory` / `batt2Factory` | — | Battery vendor | ⬜ |

### 🔌 Grid — `/grid/.../realtime`

| Field | Unit | Meaning | Used |
|-------|------|---------|:----:|
| `pac` | W | Grid power, **+ import / − export** | ✅ |
| `fac` | Hz | Grid frequency | ⬜ |
| `pf` | — | Power factor | ⬜ |
| `qac` | VAR | Reactive power | ⬜ |
| `etodayFrom` / `etodayTo` | kWh | Imported / exported **today** | ⬜ |
| `etotalFrom` / `etotalTo` | kWh | Imported / exported **lifetime** | ⬜ |
| `vip[]` | — | Per-phase `{volt, current, power}` | ⬜ |
| `status` / `acRealyStatus` | — | Grid / relay status | ⬜ |
| `limiterPowerArr[]` / `limiterTotalPower` | W | Export limiter / CT clamp readings | ⬜ |

### 🏠 Load — `/load/.../realtime`

| Field | Unit | Meaning | Used |
|-------|------|---------|:----:|
| `totalPower` / `upsPowerTotal` | W | Total load now | ✅ |
| `dailyUsed` | kWh | Load energy today | ✅ |
| `totalUsed` | kWh | Load energy lifetime | ⬜ |
| `vip[]` | — | Per-phase `{volt, current, power}` | ⬜ |
| `upsPowerL1` / `L2` / `L3` | W | Per-phase backup/UPS load | ⬜ |
| `loadFac` | Hz | Load frequency | ⬜ |
| `smartLoadStatus` | — | Smart-load relay state | ⬜ |

### ⚡ Inverter output — `/realtime/output`

| Field | Unit | Meaning | Used |
|-------|------|---------|:----:|
| `pac` | W | AC output power | ✅ |
| `pInv` | W | Inverter power | ⬜ |
| `fac` | Hz | Output frequency | ⬜ |
| `vip[]` | — | Per-phase `{volt, current, power}` | ⬜ |

### 🏷️ Inverter metadata — `/inverters`

`sn`, `alias`, `model` (`equipModel`), `status` (online/offline), `plant.id` + `plant.name`,
`softVer` / `hmiVer` (firmware), `gsn` (datalogger serial).

### 📈 History — `/plant/energy/{plantId}/day` (upstream)

Per-plant, per-day, **5-minute resolution (~288 points/day)**. Series:
**PV** (W), **Battery** (W), **SOC** (%), **Load** (W), **Grid** (W). This is the
upstream feed `recover` reads to backfill logger-offline minutes — the dashboard's
own day chart comes from `api_history`, built on our minute log.

**How far back:** any date is accepted, but the cloud only has data from when the
plant first reported — i.e. commissioning, **not** a fixed retention window. Dates
before that return `HTTP 200` with an **empty** `infos` array (no error), so the
caller treats "empty" as "no data for this day". On this account data begins
**2026-05-26**. The history window therefore grows by one day per day; it isn't
trimmed from the back. `api_history_earliest` reports the floor.

Note the *5-minute detail* above is not retained indefinitely — roughly 1–2 weeks —
which is why `recover` sweeps a rolling 14-day window and why keeping our own
minute log matters at all. The daily/monthly **kWh totals** do go back to
commissioning, and those are what `sync-plant-energy` caches.

---

## High-value additions not yet on the dashboard

Both are *already fetched* — only display work remains:

1. **Grid import/export kWh** (`etodayFrom`/`etodayTo`, `etotalFrom`/`etotalTo`) — billing / self-consumption.
2. **Per-string PV** (`pvIV[].vpv/ipv/ppv`) — panel-string diagnostics.

Also cheap to add: battery throughput (`etodayChg`/`etodayDischg`), lifetime PV (`etotal`),
per-phase + UPS/backup load, power factor & frequencies.

## Data caveats

- SunSynk's cloud updates ~once/minute — that's the real "live" ceiling.
- Junk sensor values appear: one inverter reports battery `temp: -100 °C`. Filter
  obviously-bad readings before displaying.
- Lifetime totals can look low (`etotalChg ≈ 37 kWh`) — the plant only started
  reporting to SunSynk Connect on **2026-05-26**, so there are only a few days of
  history regardless of what the inverter serials (2508…, 2512…) suggest.
- Battery power sign convention varies by firmware — see `BATTERY_POSITIVE_MEANS` in `.env`.
</content>
</invoke>
