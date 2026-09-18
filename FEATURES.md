# SunSynk Dashboard — Feature Ideas

A running backlog of what the dashboard could become. It started as a personal tool
for two inverters and is now heading to outside users; launch readiness is tracked in
`LAUNCH.md`, this file is the feature list.

See `API.md` for the field catalog this references.

**Legend**
- Effort: 🟢 small (hrs) · 🟡 medium (a weekend) · 🔴 large (multi-weekend / rabbit hole)
- Data: ✅ already fetched · ⬜ available in SunSynk API, not yet used · 🆕 needs a new source

---

## ✅ Agreed roadmap — reviewed 14 Aug 2026

Everything below survived a pass over what's *actually shipped* (tariff/savings, runtime
estimate, self-sufficiency, battery-balance banner, trends and
wall-display mode are all done). These are the real remaining gaps, to be worked through
**one at a time, in this order**.

| # | Feature | Why it matters | Effort | Status |
|:-:|---------|----------------|:------:|:------:|
| 1 | ~~**Solar forecast for tomorrow**~~ **DONE** — `forecast` Edge Function + `api_forecast()`, outlook card under Trends → Energy, and a forward line on the day chart | Everything else is backwards-looking. This is the only feature that changes what you *do* tonight (hold charge or not). | 🟡 | ✅ |
| 2 | ~~**Alerts that reach your phone**~~ **DONE** — detection here (`api_alerts_due`, `alerts-due` function, migrations 0016/0017); delivery in `prince-todo-app` (`solar-alerts`, its migrations 0069/0070). Design notes in `DATA_PIPELINE.md` §13 | Covers logger stopped, bank drift, hot battery, overnight SoC, dead string. Grid alerts ship deliberately ungated as a live test — see the open question below. | 🟡 | ✅ |
| 3 | **Outage log** — ⚠ **blocked on verification, see below** | "Off-grid 5 h 20 m this month across 7 outages, battery carried all of it." Turns the logging into a story. | 🟡 | ⬜ |
| 4 | **CSV / JSON export** of the logged history | The whole premise is owning the history SunSynk throws away — and there's currently no way to get it out. | 🟢 | ⬜ |
| 5 | **Records & streaks** — best solar day, longest fully-solar run, lowest-import week | Free from data already banked. Pure enjoyment. | 🟢 | ⬜ |
| 6 | **Load anomaly detection** — flag a jump in the stable overnight baseline | Catches the geyser/pool pump stuck on, which is real money. | 🟡 | ⬜ |
| 7 | **Battery health trend** — cumulative cycles + kWh delivered per cycle, by month | Exactly the question permanent logging exists to answer; only gets better with time. | 🟡 | ⬜ |
| 8 | **String sibling comparison over time** — A vs B divergence across weeks | The Solar tab flags a *dead* string live; slow soiling/shading drift is invisible. | 🟡 | ⬜ |
| 9 | **Service worker** — `manifest.webmanifest` exists but there's no `sw.js` | Installs but doesn't work offline and can't do web push; would make #2 land as a real phone notification. | 🟡 | ⬜ |

### ✅ Answered — grid presence (raised 18 Aug 2026, closed 18 Sep 2026)

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

**Update 5 Sep 2026 — first relay-open minute observed, question still open.** On
4 Sep at 11:15 SAST the master logged relay 0 / 0 Hz / 0 W with output pinned to
230.0 V / 50.00 Hz during a ~2 min outage — and `grid_volt_v` read **242.9 V**. That
looks like the "signal is sound" row above, but it isn't proof: with the relay closed
`grid_volt_v` and `output_volt_v` are the same number (mean |diff| 0.06 V over 5,759
minutes), and at 11:15 they differed by 12.9 V. The two sensors sit on opposite sides of
the relay, so the grid-side one was seeing mains that had already **returned** — the
sample landed in the reconnect delay, not in the dead-grid interval, which fell between
one-minute polls entirely. Nobody has yet seen a dead-grid reading.

Migration `0029` + `poll` now take a burst of ~10 s samples into `grid_burst` whenever
a poll sees the relay open or voltage under 100 V, so the next outage answers this
directly. Read it with `scripts/sql/grid-burst.sql`. Two related facts from the same
investigation: the slave's SunSynk feed repeats the previous minute 79.5% of the time
(≈5 min real resolution), and `grid_down`'s `false_3m >= 3` debounce cannot be met by an
event this short regardless of which signal is used.

**ANSWERED 18 Sep 2026 — a dead grid reads a few volts, and the voltage test is
sound.** Mains failed at 16:09 SAST and stayed off past 16:46, across both plants
and all five inverters. `grid_burst` caught it from 17 s in. While the utility was
genuinely dead: `grid_freq_hz` **0.00** and `grid_relay_status` **`0`** everywhere;
`grid_volt_v` exactly **0.0 V** on plant 495944's three inverters, and **15.2 V
decaying to 7.3 V** over 37 minutes on 538820's master with **5.5 V** on its slave —
sensor float, not mains, and far under the 100 V floor. Output stayed live at
217–230 V on all five: islanding. So the table above resolves to its middle row.
`q_grid_present`'s `> 100` test is correct and the Grid on/off chip is trustworthy.
The queries that produced this are in `scripts/sql/outage-2026-09-18.sql`.

**The return was captured too, at 17:18:14:** `grid_volt_v` jumped 6.6 → 241.0 V and
`grid_freq_hz` 0.00 → 49.86 in the *same* sample, relay still `0`, no current flowing —
then 92 seconds of reconnect delay before the relay closed at 17:20:06, output snapped
from its islanded 230.0 V / 50.00 Hz to 237.7 V / 49.90 Hz and 187 W began to flow.
Presence turns true on the 17:19 minute and "Grid is back" comes due at 17:21, which is
just after power is genuinely usable. So "back" meaning *utility live* rather than
*relay closed* is right, and the two-minute debounce absorbs the reconnect delay on its
own.

**Frequency is not the test — but the earlier reasoning here was wrong.** It said
frequency sits on the inverter side of the relay; the 17:18 sample refutes that, since
Hz returned with the mains while the relay was still open. And `0015`'s "54% of minutes
read zero frequency" describes the history logged up to Aug 2026, not this firmware
today: cross-tabulated over the last seven days on the master, `grid_freq_hz = 0` covers
70 minutes, every one of them this outage, against 8,741 minutes of relay closed / volts
up / non-zero Hz at an average of just 32 W across the CT. On this week's data frequency
would have worked.

The reason it is still the wrong column has nothing to do with the physics:
`grid_freq_hz` arrives through `extract.ts`'s `num()`, which turns an absent or
unparseable field into **0**, while `grid_volt_v` uses `numOrNull` and reads NULL. The
same API hiccup is a silent blackout on frequency and an honest "unknown" on voltage.
The 4 Sep 11:15 minute is the matching observation — 0.00 Hz alongside 242.9 V for one
minute as the inverter tripped, before it re-locked. Frequency is fair corroboration and
worth storing; nothing should branch on it alone.

**Two defects the same outage exposed, both fixed in `0055`.** The alert did not
arrive until 16:14 — five minutes of darkness — and neither minute of the delay was
the signal's fault.

1. *A stale inverter out-voted a fresh one.* 538820's slave uploads about every five
   minutes, so its rows for 16:08–16:10 all carried `device_time` frozen at 16:05:54
   with a pre-outage 240.1 V. Presence was `bool_or(grid_volt_v > 100)` over every row
   at the minute, so that one frozen sample reported "grid present" for two minutes
   after the master had already gone dark. `q_grid_present` now answers from the rows
   carrying the **newest `device_time`** at that minute and ignores the rest: each
   row's `device_time` names the moment its voltage describes, so an older row is not
   evidence against a newer one. Over the last 7 days and 16,283 minutes this changes
   exactly those 2 minutes and nothing else — nothing flipped the other way and no
   minute became unknown.

   The council rejected the first attempt, which ignored a row whose `device_time`
   repeated its own previous row and fell back to counting every row when none was
   fresh. The master uploads about every 67 s against a 60 s poll, so on 736 minutes
   of the last week (8.3%) *no* row moved — and on any of those the fallback would
   have handed the vote straight back to the frozen 240.1 V, flipping presence to
   "grid on" mid-outage and potentially firing "Grid is back" while the grid was
   dead. Today's outage happened to miss those minutes; the design should not depend
   on that. Ranking by `device_time` has no such hole, needs no cadence guessed and
   no threshold picked, and the comparison is plain text order because `device_time`
   is `'YYYY-MM-DD HH24:MI:SS'` and only ever compared within one plant at one
   minute.
2. *The confidence wording was inverted.* `0017` hedged to "Grid may be off …
   unconfirmed" whenever the relay was open, because voltage might have been merely
   tracking the relay. It is not — but anti-islanding opens the relay within seconds
   of losing mains, so a real blackout always reads relay `0`, and the confident
   branch (relay closed, no volts) was the unreachable one. Today's genuine outage
   returned the hedge. There is now a single **"Grid is off"**, with the relay out of
   the test entirely.

The debounce stays at three minutes — deliberate relay-open stretches never read under
100 V, so they were never what it guarded — but it now counts the three newest minutes
with a *known* answer rather than three clock slots in a 180-second window, so a poll
lost to a gateway timeout no longer postpones the alert. Replayed against the real
minutes, `grid_down` comes due at **16:11 instead of 16:14**.

**Three-phase: this protects three-phase PLANTS, not three-phase HOUSEHOLDS.** The
distinction is the whole safety boundary and it is easy to miss. `phase_down` reads L1,
L2 and L3 off *one inverter's row*, so it only ever sees the legs that inverter itself
senses.

| Setup | What the rows hold | Covered? |
|---|---|---|
| Three-phase inverter (e.g. `SG04LP3`) | L1/L2/L3 all populated on each row | **Yes** |
| Three-phase house, single-phase inverter on one leg | L2/L3 null — other two legs invisible | **No** |
| Three-phase house, three single-phase inverters, one per leg | each row has only its own leg as L1, L2/L3 null | **No, and worse** |

Plant 495944 is the first kind: all three of its inverters report three phases, and
their output legs read ~219 V each, so each unit senses the whole board. It is covered
by the fix.

The third row is the dangerous one and this codebase has no model for it. `phase_down`
could never fire, because it needs L2/L3 on a single row. And presence is
`bool_or(grid_volt_v > 100)` across inverters, so **one live leg out of three reads as a
healthy grid** — two-thirds of the house dark, chip says "Grid on". Detecting that means
comparing `grid_volt_v` *between* inverters and knowing which leg each sits on, which is
a different rule and needs a fact nothing records today. Worth knowing before anyone
links a plant wired that way.

**`phase_down` is worse than defect 1 and is NOT fixed.** It carries the same
unfiltered `bool_or` over possibly-stale rows, which on plant 495944 — three-phase, so
this is live, not latent — could show "Phase down" off a frozen reading. But the
council found a larger fault underneath, verified by running the deployed function
against synthetic three-phase rows:

```
L1 dead (4 V), L2/L3 live (231/229 V)  ->  q_grid_present = FALSE, phase_down = FALSE
L2 dead (4 V), L1/L3 live (231/229 V)  ->  q_grid_present = TRUE,  phase_down = TRUE
```

`q_grid_present` votes on `grid_volt_v` (L1) alone, and `phase_down` requires
`grid_volt_v > 100` before it will test `least(L2, L3)`. So a dropped L1 sets neither:
the chip reads "Grid off" and `grid_down` fires after three known minutes while two
phases are live and the house is two-thirds powered. A dropped L2 or L3 is caught
correctly. The check is one-third blind.

The agreed shape, not yet built: make presence any-phase with
`greatest(grid_volt_v, grid_volt_l2_v, grid_volt_l3_v) > 100` and the drop test
all-phase with `least(...) < 100`, both over 0055's newest-`device_time` rows; delete
the `coalesce(..., 999)` sentinel, since Postgres `least`/`greatest` already skip NULLs
and the sentinel currently makes a *missing* phase read as a healthy 999 V; widen
0055's voter filter, which requires L1 non-null and would exclude a three-phase
inverter whose L1 field alone went missing; and make a dropped phase an alert in
`api_alerts_due_raw` with `grid_down`'s debounce rather than a third state on the
presence chip, since it is an electrician call. Phase count stays out of
`plant_config`: it is an inverter fact, not a plant fact, and is inferable from whether
L2/L3 are ever reported.

What the existing data already settles, so this needs no new capture: single-phase
firmware returns NULL for L2/L3 (538820, 0 non-null rows), three-phase firmware returns
all three and writes a real 0.0 when a leg is dead (495944, 7,509 rows each). So
single-phase units do not pad with zeros, and the null-based `least`/`greatest` form is
safe. What is still unobserved is a three-phase plant while grid-connected: 495944 has
never once read above 0.0 V on any phase, and `0057`'s `grid_seen` exists to say when
that changes.

`grid_burst` has done its job and comes out in `0056`, per the 5 Sep decision. The
reconnect window was the last thing minute rows could not show, and it showed it. The
sub-minute-outage question from 4 Sep is *not* foreclosed by the drop: the burst only
ever armed on the minute after a poll saw the trigger, so it could never have answered
that one. If it ever matters it wants continuous 10 s grid polling, not this table.

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


## Not supported (as of 2026-09-12)

- **Generator input** and **external / smart meters**: the API fields exist but nothing maps them; a plant with either shows only what the inverter itself measures.
- **More than one SunSynk cloud region**: only openapi.sunsynk.net.
- **Forecast** is fitted to one site, the calibration plant; other plants see no outlook.
- **No best-day line on the day chart.** Removed 14 Sep 2026 (0052); the smooth replacement is planned in `BEST_DAY_CURVE.md`.
