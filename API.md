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
> 404s. The current flow (implemented in `server.js` → `login()`) is:

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

## This app's HTTP routes (what `server.js` serves)

| Route | Returns |
|-------|---------|
| `GET /api/overview` | Aggregated + per-inverter live snapshot (see below) |
| `GET /api/history?date=YYYY-MM-DD` | Per-plant 5-min day series (defaults to today). Logged days are a complete 5-min grid — `value: null` marks buckets with no data anywhere, `est: true` marks cloud-recovered buckets (`source='plantfeed'` rows), `gapMinutes` counts truly-missing minutes, `recoveredMinutes` counts cloud-recovered ones. Viewing a day with holes triggers recovery |
| `GET /api/history/earliest` | `{ earliest: "YYYY-MM-DD" }` — first day with data (≈ commission date); lower bound for the day picker. Cached for the process lifetime |
| `GET /api/db/stats` | Local history-log health: `{ rows, days, first, last }` |
| `GET /api/trends/by-hour?days=N` | Avg power per hour-of-day (local time) from the local log: `pv_w / load_w / grid_w / soc / surplus_w`. Basis for geyser/load timing |
| `GET /api/integrity?days=N` | Physics audit (DATA_PIPELINE.md §9A/§9B): per-day energy-balance residual, battery-sign-vs-SOC violations, gap minutes, and `flags`. Same engine as `npm run check` |
| `GET /api/debug/:sn` | Raw passthrough of the 5 realtime endpoints for one inverter — use this to discover/verify fields |

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

### 📈 History — `/api/history`

Per-plant, per-day, **5-minute resolution (~288 points/day)**. Series:
**PV** (W), **Battery** (W), **SOC** (%), **Load** (W), **Grid** (W).

**How far back:** any date is accepted, but the cloud only has data from when the
plant first reported — i.e. commissioning, **not** a fixed retention window. Dates
before that return `HTTP 200` with an **empty** `infos` array (no error), so the UI
treats "empty" as "no data for this day". On this account data begins **2026-05-26**
(verified by walking the yearly/monthly energy endpoints — every earlier
year/month comes back empty). The history window therefore grows by one day per
day; it isn't trimmed from the back. `/api/history/earliest` reports the floor.

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
