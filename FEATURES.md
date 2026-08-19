# SunSynk Dashboard — Feature Ideas

A running backlog of everything this personal tool *could* become. Framing is
**utility + enjoyment for my own two inverters**, not a product — so no auth/legal
constraints, just "would I use it and have fun building it."

See `API.md` for the field catalog this references.

**Legend**
- Effort: 🟢 small (hrs) · 🟡 medium (a weekend) · 🔴 large (multi-weekend / rabbit hole)
- Data: ✅ already fetched · ⬜ available in SunSynk API, not yet used · 🆕 needs a new source

---

## ✅ Agreed roadmap — reviewed 14 Aug 2026

Everything below survived a pass over what's *actually shipped* (tariff/savings, runtime
estimate, self-sufficiency, clear-sky potential line, battery-balance banner, trends and
wall-display mode are all done). These are the real remaining gaps, to be worked through
**one at a time, in this order**.

| # | Feature | Why it matters | Effort | Status |
|:-:|---------|----------------|:------:|:------:|
| 1 | ~~**Solar forecast for tomorrow**~~ **DONE** — `forecast` Edge Function + `api_forecast()`, outlook card under Trends → Energy, and a forward line on the day chart | Everything else is backwards-looking. This is the only feature that changes what you *do* tonight (hold charge or not). | 🟡 | ✅ |
| 2 | ~~**Alerts that reach your phone**~~ **DONE** — detection here (`api_alerts_due`, `alerts-due` function, migrations 0016/0017); delivery in `prince-todo-app` (`solar-alerts`, its migrations 0069/0070). Design notes in **`ALERTS_HANDOFF.md`** | Covers logger stopped, bank drift, hot battery, overnight SoC, dead string. Grid alerts ship deliberately ungated as a live test — see the open question below. | 🟡 | ✅ |
| 3 | **Outage log** — ⚠ **blocked on verification, see below** | "Off-grid 5 h 20 m this month across 7 outages, battery carried all of it." Turns the logging into a story. | 🟡 | ⬜ |
| 4 | **CSV / JSON export** of the logged history | The whole premise is owning the history SunSynk throws away — and there's currently no way to get it out. | 🟢 | ⬜ |
| 5 | **Records & streaks** — best solar day, longest fully-solar run, lowest-import week | Free from data already banked. Pure enjoyment. | 🟢 | ⬜ |
| 6 | **Load anomaly detection** — flag a jump in the stable overnight baseline | Catches the geyser/pool pump stuck on, which is real money. | 🟡 | ⬜ |
| 7 | **Battery health trend** — cumulative cycles + kWh delivered per cycle, by month | Exactly the question permanent logging exists to answer; only gets better with time. | 🟡 | ⬜ |
| 8 | **String sibling comparison over time** — A vs B divergence across weeks | The Solar tab flags a *dead* string live; slow soiling/shading drift is invisible. | 🟡 | ⬜ |
| 9 | **Service worker** — `manifest.webmanifest` exists but there's no `sw.js` | Installs but doesn't work offline and can't do web push; would make #2 land as a real phone notification. | 🟡 | ⬜ |

### ⚠ Open question — grid presence (raised 18 Aug 2026)

Item #3 was originally scoped as "grid failures are already in `grid_w`". **That was
wrong.** `grid_w` and `grid_freq_hz` both read zero during an ordinary self-powered
afternoon, so a blackout and a sunny day are byte-identical — 54% of all logged minutes
read zero frequency, in stretches up to 4 days.

Migration `0015` therefore started recording `readings.grid_volt_v` and
`grid_relay_status` on **18 Aug 2026**. Mains voltage reads ~240 V whenever the utility
is live, whether or not current flows. There is **no history** — it works from that date
forward only.

**Still unverified:** we have only ever observed the relay CLOSED. Nobody has seen what
voltage does when it opens. Run this in the Supabase SQL editor:

```sql
select to_char(to_timestamp(ts) at time zone 'Africa/Johannesburg','Mon DD HH24:MI') as when,
       sn, grid_volt_v, grid_relay_status, grid_freq_hz, grid_w
from readings
where grid_volt_v is not null and grid_freq_hz < 10
order by ts desc limit 20;
```

| Result | Meaning |
|---|---|
| empty | hasn't happened yet — relay-open minutes ran 0–13% of recent days |
| volts ~240, relay 0 | signal is sound; #3 is buildable and the Grid on/off chip is trustworthy |
| volts 0 whenever relay opens | voltage tracks the relay, not the mains — the chip would misreport a self-powered afternoon as "Grid off". Require voltage AND `acRealyStatus` to agree, or fall back to the SoC-below-reserve inference |

Grid alerts under #2 depend on the same answer.

---

## 1. Quick wins — surface data already in hand

| Feature | Data | Effort |
|---------|:----:|:------:|
| Grid **import/export kWh** tiles (today + lifetime) | ⬜ | 🟢 |
| **Per-string PV** detail (V/A/W per string) on inverter cards | ⬜ | 🟢 |
| **Battery throughput** today (charged / discharged kWh) | ⬜ | 🟢 |
| **Lifetime PV** total + per-inverter yield | ⬜ | 🟢 |
| Filter junk sensor values (e.g. `temp: -100°C`) before display | ✅ | 🟢 |
| Power factor / grid + output frequency readouts | ⬜ | 🟢 |
| Per-phase voltage/current (future-proof for 3-phase) | ⬜ | 🟢 |

## 2. ⚡ Load-shedding intelligence *(the centrepiece)*

| Feature | Data | Effort |
|---------|:----:|:------:|
| **Backup runtime estimate** — "4.2 hrs left at current load" from SoC + capacity + load | ✅ | 🟡 |
| Pull my area's schedule from **EskomSePush API** (free tier) | 🆕 | 🟡 |
| "**Covers tonight's Stage 4 slot** with 50 min to spare" (runtime vs next slot) | 🆕 | 🟡 |
| Alert: *"battery won't outlast the 20:00 slot — shed load"* | 🆕 | 🟡 |
| Alert: *"grid restored, charging resumed"* | ✅ | 🟢 |
| **Pre-charge reminder** before an upcoming slot | 🆕 | 🟡 |
| Countdown widget to next slot + reserve headroom | 🆕 | 🟡 |

## 3. 📊 History warehouse & analytics

| Feature | Data | Effort |
|---------|:----:|:------:|
| ~~**Log readings to SQLite** every poll (start banking history now)~~ **DONE** — `db.js`, 60s server-side poller + cloud backfill | ✅ | 🟢 |
| Self-consumption % (PV used on-site vs exported) | ✅ | 🟡 |
| Multi-day / month / year trend views | ✅⬜ | 🟡 |
| "Best/worst solar day", streaks, records | ✅ | 🟢 |
| Battery cycle counter & depth-of-discharge tracking | ⬜ | 🟡 |
| Compare inverter A vs B performance over time | ✅ | 🟡 |
| Export to **CSV** | ✅ | 🟢 |
| Backfill history from SunSynk's `/day` endpoint on first run | ⬜ | 🟡 |

## 4. 🔔 Alerts & notifications

| Feature | Data | Effort |
|---------|:----:|:------:|
| Battery SoC below threshold | ✅ | 🟢 |
| Sustained grid-import spike (unexpected load) | ✅ | 🟢 |
| PV string drops out / underperforms vs its sibling | ⬜ | 🟡 |
| Inverter offline / stopped reporting | ⬜ | 🟢 |
| Battery temperature out of range | ✅ | 🟢 |
| Delivery channels: push, email, Telegram/Discord bot, ntfy | 🆕 | 🟡 |

## 5. 📱 Mobile & widgets *(iOS-dev wheelhouse)*

| Feature | Data | Effort |
|---------|:----:|:------:|
| **Home/Lock-Screen widget** — live SoC + solar + load, glanceable | ✅ | 🟡 |
| Native iOS app shell over the existing backend | ✅ | 🔴 |
| Live Activity / Dynamic Island during a load-shedding slot | 🆕 | 🔴 |
| Apple Watch complication (SoC %) | ✅ | 🔴 |
| Responsive / installable PWA (cheaper than native) | ✅ | 🟡 |

## 6. 🔋 Battery health & diagnostics

| Feature | Data | Effort |
|---------|:----:|:------:|
| Charge/discharge current vs BMS limits gauge | ⬜ | 🟡 |
| Target charge/discharge voltage display | ⬜ | 🟢 |
| Capacity / state-of-health trend over months | ⬜ | 🔴 |
| Per-pack breakdown if a second bank is ever added | ⬜ | 🟡 |

## 7. ☀️ Solar / PV diagnostics

| Feature | Data | Effort |
|---------|:----:|:------:|
| Per-string yield ranking + underperformance flag | ⬜ | 🟡 |
| Shading/soiling detector (string A vs B divergence) | ⬜ | 🟡 |
| Theoretical-vs-actual using a sun-position/irradiance model | 🆕 | 🔴 |

## 8. 💰 Cost & tariff tracking

| Feature | Data | Effort |
|---------|:----:|:------:|
| Enter my **tariff** (incl. City Power blocks/TOU) → daily savings in Rand | 🆕 | 🟡 |
| Grid spend avoided vs solar+battery contribution | ✅🆕 | 🟡 |
| Payback / ROI tracker for the install | 🆕 | 🟡 |
| Feed-in credit estimate if exporting | ⬜🆕 | 🟡 |

## 9. 🏠 Automations & integrations

| Feature | Data | Effort |
|---------|:----:|:------:|
| **Home Assistant** entities (MQTT/REST) | ✅ | 🟡 |
| Trigger loads when surplus solar (geyser, pool pump) | ✅🆕 | 🔴 |
| Defer high loads when SoC low / slot imminent | ✅🆕 | 🔴 |
| Webhooks / IFTTT-style rules engine | ✅ | 🔴 |

## 10. 🔌 Data-source upgrades

| Feature | Data | Effort |
|---------|:----:|:------:|
| **Local Modbus/RS485 read** — works during internet outages, ~1s refresh, no cloud dependency | 🆕 | 🔴 |
| Hybrid: local when available, cloud fallback | 🆕 | 🔴 |
| Token/refresh hardening + smarter rate-limit backoff | ✅ | 🟢 |
| Multi-account support (if I ever monitor someone else's) | ✅ | 🟡 |

## 11. 🎨 UI / UX polish

| Feature | Data | Effort |
|---------|:----:|:------:|
| Light/dark theme toggle | — | 🟢 |
| Configurable tile layout / drag-reorder | — | 🟡 |
| Mobile-first responsive layout | — | 🟡 |
| Richer energy-flow animation (battery fill, directional speed by power) | ✅ | 🟡 |
| Per-inverter drill-down page | ✅ | 🟡 |

## 12. 🌀 Wild ideas / someday

- Daily "energy report" summary (push or email each morning).
- Voice: "Hey Siri, how's my battery?" via Shortcuts + the API.
- Weather-forecast-aware battery strategy ("cloudy tomorrow — hold charge").
- Anomaly detection on consumption (fridge left open, geyser stuck on).
- E-paper / Raspberry Pi wall display in "control-room" theme.
- Public read-only share link for a single live tile.

---

## Suggested phasing

1. **Quick wins (§1)** + **SQLite logger (§3)** — low effort, and the logger should run ASAP so history accumulates.
2. **Load-shedding intelligence (§2)** — the centrepiece; most daily utility.
3. **Alerts (§4)** — small additions once the data + thresholds exist.
4. **Joy project:** pick the **iOS widget (§5)** *or* the **local Modbus rebuild (§10)**.
5. Everything else as the mood strikes.
</content>
