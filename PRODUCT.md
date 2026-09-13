# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Homeowners with a SunSynk inverter install, checking their own house. They use it on
whatever is to hand: phone, desktop browser, and tablets (including a tablet fixed to a
wall in fullscreen). No device is secondary.

Confirmed other audiences: none yet. Installers managing many plants are not a target;
the plant switcher exists for users who own more than one plant.

Today's only production user is the owner (two inverters, Johannesburg). The next step
is a stranger signing up, so every screen has to work for a plant the author has never
seen: one or many inverters, with or without a battery, with or without a grid, exporting
or not, single or three-phase, any currency, any timezone.

## Product Purpose

A dashboard for a SunSynk Connect solar install: live solar, battery charge, grid
import/export, home load, an animated energy-flow diagram, day charts, and long-run
trends across every inverter on the account.

Its reason to exist is its own history. It logs every minute (plant totals forever,
per-inverter detail for 90 days), so trends, battery-health checks, integrity checks and
the self-calibrating solar forecast rest on real data rather than the cloud's fading
summary.

Success: a homeowner connects their SunSynk login once and then understands, at a glance,
what their system is doing now and whether it is healthy over time. Tonight's decision
(hold charge or not) is the one forward-looking job.

## Positioning

Permanent minute-by-minute history. SunSynk's cloud drops detail after a week or two;
this keeps every minute, so the trends, battery health and integrity views are real, not
reconstructed. Everything else (combined multi-inverter view, forecast, alerts) builds on
that log.

## Operating Context

- **Data path:** a Supabase backend polls SunSynk's official API once a minute per
  inverter and stores readings in Postgres. The browser reads Postgres only, through
  `api_*` functions behind row-level security; it never talks to SunSynk.
- **Onboarding:** sign up, then enter the SunSynk Connect login once on the Connect
  screen. The password is exchanged for a token and dropped. If the SunSynk password
  changes, the account flips to "needs relink" and the app asks for it again.
- **Screens:** Live, Solar, Battery, Grid, Inverters (the middle four can be hidden in
  Settings), Trends, Settings. Logged-out: sign in, sign up, password reset, Connect,
  Terms, Privacy.
- **Situations:** glance on a phone; a wall tablet in fullscreen (installable PWA);
  a longer sit-down look at trends on a desktop. Load-shedding and outages are a normal
  part of life for the current plant, so "grid gone, battery carrying the house" is a
  state the UI must read well.
- **Freshness:** a master inverter reports every minute; a slave every 5 minutes. About
  a third of polls currently time out at the gateway on the free quota, so a minute with
  no data is ordinary and must be shown as a gap, not hidden.
- **Backlog and readiness** live in `FEATURES.md`, `LAUNCH.md` and `READINESS.md`.

## Capabilities and Constraints

Confirmed functionality:

- Live power flow, per-inverter cards, battery gauge, runtime estimate, reserve, grid
  presence per phase, grid voltages per inverter.
- Day chart with an expected-solar line and a forward forecast line; Trends over
  today / week / month / year / lifetime; savings against a user-entered tariff and
  feed-in rate; self-sufficiency.
- Solar forecast (Open-Meteo irradiance, refitted weekly to this array's own log) for the
  calibration plant only; other plants get an honest "not available here" message.
- Alerts (logger stopped, bank drift, hot battery, overnight charge, dead string) are
  detected here but delivered through a separate app, so today only the owner receives
  them.
- Auto-detected per-plant config: has battery, has grid, battery sign convention, bank
  model (per-inverter or shared), with user override in Settings.
- Account: sign out, delete account, disconnect any linked SunSynk account, timezone,
  tariff, support address and version in Settings → About. Browser errors are logged to
  a `client_errors` table.

Technical constraints:

- No build step. React 18 and Babel Standalone from a CDN; JSX transpiled in the browser.
  A syntax error blanks the page silently, so every `.jsx` is checked with esbuild before
  a deploy.
- Frontend is static on GitHub Pages; backend is Supabase (Postgres, Edge Functions,
  pg_cron). The two ship separately, backend first.
- Cost per customer is real: ~450 MB per inverter per year, one SunSynk poll per minute
  per inverter, and an app key whose terms for polling other people's accounts are not
  yet confirmed with SunSynk.

Terminology (user-facing): "Solar" not PV; "Charge" not SOC; "Full today"; "Panel
capacity (kW)"; "expected solar" not clear-sky. Live power is shown in kW, energy in kWh
(MWh above 1000).

Undecided product facts:

- Terms and privacy copy are placeholders (`public/legal.jsx`), flagged on screen.
- Plan caps: `profiles.plan` exists; nothing enforces it. Free service for now.
- Analytics and crash reporting: none. Deferred.
- Email: Supabase's default sender only; custom SMTP not set up.
- Generator and external-meter setups: out of scope.

## Brand Commitments

None made binding (confirmed 2026-09-12). The following exist today and are evidence, not
commitments, so a redesign may revisit them:

- Name "Prince Solar"; legal entity Theron and Prince Solutions (Pty) Ltd, South Africa.
- A sun icon (`public/icon.svg`, PNGs at 180/192/512) used as favicon and PWA icon.
- The app currently ships dark only; a light-scheme device sees the same dark page.
- A fullscreen wall-tablet mode exists and is used.

## Evidence on Hand

- Real production data: the owner's two-inverter plant, logged since commissioning of
  the logger, on the live Supabase project.
- Six mock plant shapes for local testing (`scripts/mock-sunsynk/`): two inverters with
  a slow slave; exporter with three-phase and inverted battery sign; off-grid cabin;
  grid-tied with no battery; two inverters sharing one bank; a second user on a shared
  plant. These are the reference cases every screen must survive.
- Field catalog in `API.md`; pipeline design in `DATA_PIPELINE.md`.
- No testimonials, customer logos, press, benchmarks or pricing exist. Do not invent any.
- The original design handoff and mock-data prototype are in `design/`; an earlier
  vanilla-JS dashboard is in `legacy-dashboard/`. Both are history, not authority.

## Product Principles

1. **The log is the product.** Anything that hides a gap, smooths a hole, or shows a
   number the data cannot support undermines the one reason this exists.
2. **Every plant shape, first time.** The six mock shapes are the acceptance bar; a
   screen that assumes the owner's plant is a bug.
3. **Glanceable on every device.** Phone, desktop and wall tablet are all primary. A
   screen that only works at one width is unfinished.
4. **Honest about freshness and reach.** Stale, missing, or unavailable-for-this-plant is
   said plainly, never inferred away.
5. **Plain words.** User-facing copy uses the household's words (Solar, Charge, Home),
   never the inverter's.

## Accessibility & Inclusion

No formal standard adopted. Text colours were retuned to meet WCAG AA 4.5:1 on all three
surface shades, and that floor should hold for any future scheme.
