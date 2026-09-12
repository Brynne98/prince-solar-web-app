# Customer-readiness checklist

Findings from the 2026-09-12 review, ordered by what to fix first. Each item says
where it lives, what changes, and its acceptance criteria. Tick as they land.

Legend: **B** blocker · **P** plant-level · **I** inverter-level · **C** configuration · **O** onboarding/ops

## Test bed

`scripts/mock-sunsynk/` stands in for openapi.sunsynk.net on the local stack:

| SunSynk login | plant | shape |
|---|---|---|
| brynne@mock | 5001 Prince home (JHB, ZAR) | 2 inverters, master 60 s + slave 5 min, battery per inverter, import only |
| family@mock | 5001 (same plant, shared login) | second dashboard user on one plant |
| export@mock | 3001 Old exporter (London, GBP) | 1 inverter, 3-phase, exports, firmware sign = charging positive, lower plant id than 5001 |
| export@mock | 6002 Cabin (Windhoek, NAD) | off-grid, 1 inverter, battery; login paginates at 1 per page |
| nobatt@mock | 6003 Grid-tied (Sydney, AUD) | no battery, exports |
| shared@mock | 6004 Shared bank (Cape Town, ZAR) | 2 inverters, one shared pack, second-bank fields |

Dashboard users: one per customer shape (`export@`, `nobatt@`, `shared@`, `family@local.test`) so tenancy is tested per customer, plus `dev@local.test`, which links every login so the plant selector shows all shapes on one screen. Password for all: `devpassword123`.

```bash
node scripts/mock-sunsynk/server.js &
supabase functions serve --env-file scripts/mock-sunsynk/mock.env --no-verify-jwt &
eval "$(supabase status -o env | grep -E '^(API_URL|SERVICE_ROLE_KEY|ANON_KEY)=')"; node scripts/mock-sunsynk/seed-users.mjs
curl -s -X POST http://127.0.0.1:55321/functions/v1/poll -d '{}'
```

---

## Stage 1 — breaks on the first outside customer (B)

- [x] **B1 Calibration plant pinned, not min(plant_id)**
  Reproduced: linking export@mock (plant 3001) made `calibration_plant()` return 3001.
  Change: `app_config.CALIBRATION_PLANT`, set once by the first link, read by `calibration_plant()`.
  Accept: with plants 3001 and 5001 linked, `calibration_plant()` = 5001; disconnecting and relinking 3001 does not move it; a fresh stack with no key pins the first plant linked.

- [x] **B2 Battery sign per plant, auto-detected**
  Reproduced: plant 3001 (charging-positive firmware) stored `batt_w = +500` while discharging at night.
  Change: `plant_config.batt_positive_means` (null = detect); detection from stored raw power vs SoC movement; rows written under the wrong assumption flipped once on detection; Settings shows detected value with override.
  Accept: after ~1 h of mock polls, 3001 has `batt_positive_means = 'charging'`, source `detected`, and every 3001 row has `batt_w` negative at night; 5001 unchanged; user override survives the next detection pass.

- [x] **B3 One stable polling account per shared plant**
  Reproduced: family@mock never polled, its `last_ok_at` stays null.
  Change: earliest-linked active account polls the plant; every active account mapped to a plant polled this minute gets `last_ok_at`.
  Accept: ten polls, `private.inverters.account_id` for 5001 never changes; both accounts on 5001 have `last_ok_at` within the last minute; marking the primary needs_relink moves polling to the other on the next minute.

## Stage 2 — multiple plants (P)

- [x] **P1 Plant days refetched on switch** — Accept: switch plants, the empty-state copy matches the plant switched to.
- [x] **P2 Forecast copy on non-calibration plants** — Accept: on 3001 the card says the forecast is fitted to one site and not available here.
- [x] **P3 Recover and sync budgets round-robin** — cursor in `app_config`. Accept: with the budget forced to one plant per run, three runs visit three different plants.
- [x] **P4 Paginate SunSynk lists** — Reproduced: export@mock shows one plant of two. Accept: both 3001 and 6002 linked and polled.
- [x] **P5 All SunSynk accounts in Settings** — Accept: dev user sees four accounts, each with its own disconnect.
- [x] **P6 Disconnect keeps calibration** — covered by B1's accept.

## Stage 3 — multiple inverters (I)

- [x] **I1 Grid voltage from every inverter** — Accept: Grid tab lists one voltage per inverter for 5001.
- [x] **I2 Bank model** — `plant_config.battery_banks` `per-inverter | shared`. Accept: on 6004 set to shared, Battery tab says 1 bank, SoC is the master's, drift status `single`.
- [x] **I3 Second bank fields** — Accept: 6004 master card shows bank 2 SoC/voltage.

## Stage 4 — configurations (C)

- [x] **C1 No battery** — `plant_config.has_battery` auto-detected. Accept: 6003 Live shows no battery card, gauge, runtime or reserve; console has no errors; alerts return none.
- [x] **C2 Off-grid** — `plant_config.has_grid` auto-detected. Accept: 6002 shows no grid tile, no presence pill, savings copy says solar-covered.
- [x] **C3 Export** — flow shows export, Grid tab says exporting, `tariff_export`, Overview "Exported" tile. Accept: 6003 at midday shows export in flow, Grid and Overview; savings include export × feed-in.
- [x] **C4 Three-phase** — L2/L3 volts stored, presence per phase. Accept: 3001 Grid tab shows three voltages.
- [x] **C5 Plant time in the browser** — Accept: browser in Europe/London, plant 5001, the "typical at this hour" marker is at Johannesburg's hour.
- [x] **C6 Power units** — `fmtPower` and the flow say kW. Accept: no "kWh" next to a live power anywhere.
- [x] **C7 Generator / external meter** — out of scope; recorded in FEATURES.md.

## Stage 5 — onboarding and ops (O)

- [x] **O1 "No plants visible" next step** — Accept: connect screen explains the installer share and offers Retry.
- [x] **O2 Domain config in one place** — CORS origins from the `LINK_ALLOWED_ORIGINS` secret with the current list as default. The cron base URL is the project's functions host, which a site domain never changes; DEPLOY.md says where the two origin settings live.
- [x] **O3 Manifest** — Accept: `start_url` relative, no forced orientation.
- [x] **O4 Retention wording** — README and Settings say per-minute inverter rows are kept 90 days, plant totals forever.
- [x] **O5 Support link + error path** — Accept: Settings shows version and a support address; `window.onerror` writes to `client_errors`; a thrown error appears as a row.
- [ ] **O6 Terms & privacy** — deferred (2026-09-12): copy to come when ready.
- [ ] **O8 SunSynk quota** — deferred (2026-09-12): question drafted in LAUNCH.md, not sent.
- [ ] **O9 Email** — deferred (2026-09-12): Supabase default sender for now, no custom SMTP.
- [x] **O10 Analytics** — deferred.

(Plan caps: not now. `profiles.plan` stays as it is; nothing enforces it.)

---

## Stage 6 — first-look usability (2026-09-12 browser review, all fixed)

- [x] **U1 Trends copy plant-neutral** — no geyser / 20%-floor wording, no literal "≈ N%".
- [x] **U2 Energy vs Live on day one** — note under the Energy stats says the log started at link time; y-axis prints a decimal under 10 kWh.
- [x] **U3 Day chart first half hour** — "Collecting today's first readings" instead of "Only 1 day logged".
- [x] **U4 Sign out** — Account card shows the signed-in email and a Sign out button.
- [x] **U5 Words** — SOC → Charge, Full → Full today, kWp → Panel capacity (kW), clear-sky → expected-solar, both battery-sign settings renamed.
- [x] **U6 Savings hint** — Est. saved tile says "set your rate in Settings" while the rate is 0.
- [x] **U7 Phone layout** — flow-tile sub-text wraps; Energy stat tiles stack under 600 px.
- [x] **U8 Timezone** — text box with autocomplete over the zone list.
- Left as designed: the Grid tile on an off-grid plant until auto-detect runs on the first full day.

## Verified 2026-09-12

- Browser pass (dev user, desktop): Live, Battery, Grid, Inverters and Settings for 6003, 6004, 3001, 6002, 5001; phone width for 5001 (mobile flow, kW units, no horizontal scroll). No console errors on any screen. The app is dark-only by design, so a light-scheme device sees the same dark page.
- Not simulated: a dropped phase (C4's `phaseDown` path), the "no plants visible" screen (O1), a viewer in another timezone (C5). All three are code-only.
- `supabase db reset` applied 0001–0043 cleanly; the seed script relinked all users; the first link pinned `CALIBRATION_PLANT` = 5001; poll, tenancy-check and settings-check pass on the fresh stack.

## Checks that run by exit code

```bash
node scripts/mock-sunsynk/tenancy-check.mjs    # each user sees only their plants (5 users, 5 plants)
node scripts/mock-sunsynk/settings-check.mjs   # Settings round-trips, guard triggers, client_errors
```

## Proof of the whole

- `supabase db reset` applies every migration cleanly, then the seed script relinks the mock users.
- Every Edge Function runs once locally against the mock, exit 0.
- Frontend screenshots at phone and desktop width, light and dark, for: 5001 · 3001 · 6002 · 6003 · 6004.
- Nothing is committed, pushed or deployed without your say-so.
