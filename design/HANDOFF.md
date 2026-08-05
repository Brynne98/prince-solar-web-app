# SynSynk Dashboard — Build Handoff

A single-page solar-monitoring dashboard for a **SunSynk Connect** system (2 inverters,
1 battery bank each). Dark, data-dense, desktop-first. This doc is everything another
AI/dev needs to rebuild or extend it.

---

## 1. Tech stack & how it runs

- **No build step.** Plain HTML + React 18 loaded from unpkg, transpiled in-browser by
  Babel Standalone. Open `SynSynk Dashboard.html` directly.
- React/Babel are loaded with **pinned versions + integrity hashes** (keep them).
- App code is split into several `.jsx` files loaded as `<script type="text/babel" src="…">`
  **in dependency order**. Each Babel script has its own scope, so shared things are hung
  on `window` at the end of each file and read back via `window.X`.

### Load order (in `SynSynk Dashboard.html`, end of `<body>`)
1. `data.jsx` — mock data + tariffs (exports `simulateDay`, `simulateDays`, `makeSnapshot`, `TARIFF_PRESETS`, `BATT_CAPACITY_KWH`, `BATT_MAX_KW`)
2. `components.jsx` — design tokens + shared atoms + formatters (`COLORS`, `Card`, `StatTile`, `Metric`, `Badge`, `Segmented`, `Toggle`, `LegendChip`, `SectionTitle`, `InfoDot`, `fmt*`)
3. `flow.jsx` — `PowerFlow` component (the animated energy-flow diagram)
4. `chart.jsx` — `HistoryView` component (the day power chart)
5. `tabs.jsx` — `LiveTab`, `SolarTab`, `BatteryTab`, `GridTab`, `InvertersTab`, `SettingsTab`, plus `MiniStat`/`Gauge` helpers
6. `app.jsx` — `App` root: header, tab bar, live tick, localStorage persistence; mounts to `#root`

All CSS lives in one `<style>` block inside `SynSynk Dashboard.html` (class-based, no CSS-in-JS except small inline styles).

> **Gotcha:** never name a shared styles object `styles` in a Babel file — collisions break things. Use inline styles or uniquely-named consts.

---

## 2. Design system

- **Fonts:** `Space Grotesk` (display/headings/body), `JetBrains Mono` (all numerics & small labels — class `.mono`). Loaded from Google Fonts.
- **Background:** near-black `#0a0d12` with two faint radial tints. Cards `#11161d`, border `rgba(255,255,255,0.07)`, radius 16px.
- **Series palette** (CSS vars + `COLORS` in components.jsx — keep the two in sync):
  - Solar `--pv #3ddc84` (green) · Battery `--batt #a78bfa` (purple) · Grid `--grid #facc15` (yellow) · Load/Home `--load #f87171` (red) · SOC/“Charge” `--soc #22d3ee` (cyan)
  - `--ok #3ddc84` is a **separate green** for success/online/toggles, so battery’s purple never leaks into status UI.
- **Units convention (important):** the user explicitly wants **everything shown in `kWh`**, including instantaneous live values (which are technically power = kW). `fmtPower`/`fmtPowerParts` divide W by 1000 and label `kWh`. Energy totals also use `kWh`, switching to `MWh` above 1000 (`fmtEnergySmart`/`fmtEnergyParts`); large Rand uses `fmtRandSmart` (→ `R…k`). If a future dev wants correctness, this is the one place that diverges from physics on purpose.
- **Labels:** “PV” is shown as **Solar**, “SOC” is shown as **Charge** everywhere user-facing.
- Uppercase letter-spaced micro-labels; big mono numbers; subtle 1px dividers. Avoid gradients-as-decoration, emoji, and hand-drawn pictorial SVG (icons here are simple geometric/monoline).

---

## 3. Data model

Everything is driven by a **snapshot** object (live “now”) plus **time-series** (the day chart) and **daily aggregates** (period totals). Shapes mirror the real API in `uploads/API.md`.

### `makeSnapshot(jitter)` → live snapshot (data.jsx)
```
{
  updated: Date,
  plant: { id, name },
  weather: { temp, sunrise:'06:42', sunset:'17:38', desc, nowMin },   // MOCK — see §6
  aggregate: {
    pvNow, pvToday, pvTotal,                       // W, kWh, kWh
    battSoc(%), battPower(W magnitude), battState:'charging'|'discharging'|'idle',
    battVoltage(V), battCurrent(A, sign=charge/discharge), battTemp(°C),
    battChgToday, battDischgToday, battChgTotal, battDischgTotal,   // kWh
    gridPower(W, + import / − export), gridFromToday, gridFromTotal, // kWh
    gridFreq(Hz), gridPf,
    loadNow(W), loadToday, loadTotal                // kWh
  },
  inverters: [ {
    sn, alias, model, status:'online'|'offline', soft, hmi, gsn, commissioned,
    pvNow, pvToday, pvTotal, output(W),
    battPower, battState, battSoc, battVolt, battCurrent, battTemp, battCap(Ah),
    numberOfBatteries, secondBank,                  // bank/module count
    chgToday, dischgToday, grid, gridFromToday, load, loadFreq,
    strings: [ { no, v(V), i(A), p(W), today(kWh) } ],   // per-PV-string diagnostics
    phases:  [ { volt, current, power } ], ups: { l1,l2,l3 }
  } ]
}
```
- `jitter` arg: when truthy, randomizes a few live values per tick so it feels alive.
- **Bad-sensor demo:** one inverter may report `battTemp:-100`. `cleanTemp()` filters impossible readings; the header shows an orange health dot + “sensor issue”.

### `simulateDay(seed, fillMinutes)` → day series (data.jsx)
Returns `{ points:[{t(min), pv, load, batt, grid, soc}], totals:{pv,load,chg,dischg,imp} }`, 5-min resolution (288 pts). `fillMinutes` nulls points after “now”. **Series sign conventions:** `batt` + = charging / − = discharging; `grid` + = importing / − = exporting. It runs a tiny physical sim (solar bell curve → load → battery → grid) so the data is internally consistent.

### `simulateDays(n, endDate)` → daily aggregates for Week/Month/Year totals.

---

## 4. Screens (tabs in app.jsx)

- **Live** (`LiveTab`): three stacked sections via CSS `order` — (1) **Overview strip** at top: period selector `Today · Week · Month · Year · Lifetime` driving 5–6 `MiniStat`s (Generated, Consumed, Self-sufficiency, Imported, Est. saved); (2) **Power Flow** card (`PowerFlow`); (3) **History** chart card (`HistoryView`). The old 4 stat-tiles were intentionally removed — their data now lives in the flow nodes.
- **Solar** (`SolarTab`): 6 generation cards (Now/Today/Week/Month/Year/Lifetime) + **PV strings grouped per inverter** (per-string V/A/W/today, dead/shaded flag).
- **Battery** (`BatteryTab`): SOC `Gauge`, voltage/current/temp, throughput-today card with a labeled **SOC bar + user reserve marker**, bank/battery count, per-inverter breakdown.
- **Grid** (`GridTab`): grid now / imported today + lifetime / self-sufficiency, grid quality (freq, pf, voltage), and a cost & savings card (Rand) when savings layer is on.
- **Inverters** (`InvertersTab`): per-unit cards (status badge, model/fw, solar/output/battery/soc/grid/home/temp/today), bad-sensor warning.
- **Settings** (`SettingsTab`): SA **tariff** (presets + editable import rate), display toggles (savings layer, bad-sensor filter, battery sign), **battery stopping-reserve slider**, and which tabs are visible.

### PowerFlow (flow.jsx) specifics
- Layout: **Solar · Battery · Grid** (sources, left) → **Inverters** (circular hub w/ DC→AC glyph) → **Home** (right). All nodes always rendered even at 0.
- Animated particle links: **uniform thickness; only particle speed scales with power** (faster = more kW). Battery link reverses direction when charging. Links float with a gap (don’t touch nodes). Fills clip so negatives render as a line below a zero baseline.
- Node icons are simple monoline SVG (sun / battery / lightning bolt / house) with hollow outline + light fill.
- Only the **Battery** node shows a state tag (`charging|discharging`) with a **prominent bold coloured `NN%`** (the `.flow-pct` tspan) + an ETA sub (“2h 0m to empty/full”, using the reserve setting). Solar/Grid/Home show value + “X kWh today”.
- Bottom **status strip**: a one-line narrative + Solar/Battery/Grid/Home chips.

### HistoryView (chart.jsx) specifics
- Single **day** power chart (no range switch — period totals live in the Overview strip). Lines for Solar/Battery/Grid/Load, **Charge (SOC)** on a right axis. Translucent fills under Solar/Load/Grid/Battery (not SOC). X-axis only spans **midnight → now**. Hover crosshair + tooltip. A **Lines / Power balance** segmented toggle (stacked-area “where the load came from”) sits inline-right of the legend with an info icon.

---

## 5. State & persistence (app.jsx)
- `settings` (localStorage `synsynk.settings`): `{ showSavings, filterBadSensors, battPositive, reserve, tabs:{solar,battery,grid,inverters}, tariff:{preset, import} }`. Merged over `DEFAULT_SETTINGS` on load.
- Active `tab` persisted (`synsynk.tab`).
- **Auto refresh:** every 5s calls `makeSnapshot(1)`; the Refresh button pulses (green) on each refresh.
- Tweak controls follow the host Tweaks protocol is **not** used here; settings are in-app.

---

## 6. Wiring to the real system (replace the mocks)
The server (`server.js`, see `uploads/API.md`) already exposes `GET /api/overview` and `GET /api/history?date=`. To go live:
1. In **data.jsx**, replace `makeSnapshot()` with a `fetch('/api/overview')` that maps the response into the snapshot shape in §3 (field names per API.md). Replace `simulateDay`/`simulateDays` with `fetch('/api/history?date=…')` (per-plant 5-min series) and daily roll-ups.
2. In **app.jsx**, make the live tick `await` the fetch (and re-login/refresh handled server-side).
3. **Weather is fully mocked** (`weather:{temp,sunrise,sunset,desc,nowMin}`). SunSynk has no weather; wire a free source: sun times from lat/long (computed or `api.sunrise-sunset.org`), temperature from Open-Meteo. Add a `weather` object to `/api/overview`. `nowMin` drives the header daylight bar.
4. Keep `cleanTemp()` filtering and the kWh-everywhere formatting unless the owner changes their mind.

---

## 7. Conventions to preserve
- Canonical HTML (explicit closing tags, quoted attrs) so the visual editor works.
- Keep `data-comment-anchor` attributes where present.
- Battery sign + reserve are user settings — thread `settings.reserve` (fallback 20) through any new battery math.
- Don’t reintroduce a separate 4-tile stat column on Live; the flow nodes carry that data now.
