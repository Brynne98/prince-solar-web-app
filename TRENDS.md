# Trends page (removed 5 Oct 2026, SOLAR-47)

Removed to get back to basics: Live, Solar, Grid and Equipment. It will be rethought from
scratch. This note records what it had so nothing has to be rediscovered. The last
version is `public/trends.jsx` at commit `6e9f543` (v0.28.28).

## What it showed

Two views, switched at the top: **Battery** (the default) and **Energy**.

**Battery view**, range 7 / 14 / 30 days:

- **Electricity used by time of day.** Five parts of the day, kWh each, split by where the
  power came from: solar, battery, grid. RPC `api_trends_segments(p_days)`, removed in
  migration 0074.
- **Usual mix by hour.** 24 stacked hourly bars of the same split, with the typical charge
  % as a line. RPC `api_trends_by_hour(p_days)`, still used by Live (typical charge) and
  Battery ("If the grid goes off").

**Energy view**, Line or Bar, and Daily / Monthly / Seasonal:

- A stat row: Generated, Home, Self-sufficiency, as totals and averages.
- **Daily**, range 7 / 14 / 30 days: generated, home and from-grid per day, plus a dotted
  **Expected** line. Expected was the solar forecast's estimate of what that day's sunshine
  should give. RPC `api_trends_daily(p_days)`; still used by Solar's 30-day bars. The
  Expected part and the forecast itself went in 0074 (SOLAR-64).
- **Monthly**: one point per month, every year on record, from SunSynk's monthly totals.
  RPC `api_trends_monthly`, removed in 0074.
- **Seasonal**: South African seasons rolled up from the monthly rows.

## How it behaved

- It never waited for the live snapshot. It refreshed on open, on any view or range
  change, on the header Refresh, and every 5 minutes on its own timer.
- A failed load said "Couldn't load. Try again" rather than drawing an empty chart.
- Line or Bar was remembered per browser (`synsynk.trendChart`).

## Data it relied on

- `agg_minute`: the last 7–30 days at minute detail (time of day, by hour, unfinished days).
- `plant_energy`: daily and monthly totals from SunSynk, back to commissioning.
- `solar_forecast` and `solar_forecast_cal`: the Expected line, for the calibration plant only.
