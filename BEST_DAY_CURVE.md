# Best-day curve — plan

Parked 14 Sep 2026. The dotted "best recent output" line (migration 0051) is being
removed; this is what replaces it when the work is picked up.

What the removal leaves to build from:
- `supabase/migrations/0051_best_recent_output.sql` stays in the repo: the full usable-reading
  query. Migration 0052 only drops the function it created.
- The drawn line, tooltip row and progress ring (with its CSS) are in commit `fb594c8`:
  `git show fb594c8:public/chart.jsx` (around lines 376–386, 430–510, 599, 629, 711–735)
  and `git show fb594c8:public/index.html` (lines 229–236).

## What it shows

One smooth arch on the day chart, sunrise to sunset: what a good clear day looks like
for this plant right now. It is built from the plant's own readings, so no roof pitch,
direction or location is asked for.

It is a reference, not a record of one real day. Each 5-minute slot takes its own good
days, so the arch is stitched from several days and a real clear day usually sits a
little under it (measured: 2–3% on Prince Home). Cloudy days sit well under it.

## Evidence (measured 14 Sep 2026)

Scripts and the export query are in `scripts/best-day-curve/`.

Both production plants, curve fitted from the N days before each of the last 30 dates,
compared with the 30-day curve (gap as a share of peak):

| Days used | Tshigabe typical / worst gap | Prince Home typical / worst gap |
|---|---|---|
| 7  | 10% / 53% | 7% / 50% |
| 14 | 6% / 42%  | 2% / 19% |
| 21 | 3% / 10%  | 2% / 5%  |

Against Prince Home's 26 clear days (92 days of history), predicting each from the days
before it. A clear day: at least 20 usable slots between 09:00 and 13:00, and the day's
total up-and-down movement no more than 1.4 × twice its peak (clouds make it jagged).

| Window | Morning miss | Afternoon (curve too high) |
|---|---|---|
| 21 days | 3% | 3% |
| 30 days | 3% | 3% |
| 45–60 days | no better: the season moves under it | |

- Short windows fail after a cloudy week. **The line needs 21 days of readings; once
  there, it uses up to 30.**
- The battery is full by ~11:00 on sunny days, so only 15–35% of afternoon readings are
  usable (85–90% in the morning). The afternoon half is the weaker half.
- Needing ≥ 5 days per 5-minute slot cut the afternoon overshoot from 6% to 3%.
- Two arches (for two roof faces) were ~1% closer. Not worth it.
- Not yet verified in summer.

## The curve

`w(t) = A · sin(π · u^q)^p`, with `u = (t − sunrise) / (sunset − sunrise)`, zero
outside the day.

- **Points:** per 5-minute slot, the 90th percentile of each day's mean usable output
  over the 30 days before the date. Usable = battery < 95% and charge < 90% of the
  plant's ceiling, plant-feed rows excluded (the 0051 rules). These rules are a proxy:
  a missing grid reading counts as zero, and the ceiling is inferred, not known.
- **Sunrise / sunset:** first and last slot above 1% of the peak, ±1 slot. Pinned from
  readings; left free, the ends drift.
- **Shape:** `p` 0.6–3.0, lean `q` 0.4–2.0, grid search; `A` by weighted least squares.
  Weight = days in the slot; slots with < 5 days are ignored. The arch is drawn through
  them anyway — that is the point of a smooth line, and the afternoon is where it is
  least sure.
- **Shows when:** ≥ 21 days of readings and 85% of 09:00–15:00 slots filled (as 0051).
  Hidden when the fit misses its own points by more than 15% of peak.

## Build

1. **Calculation.** A new SQL function from the 0051 query that also returns each
   slot's day count (0051 returns only `t` and `w`; the fit needs the counts as weights).
2. **Store it.** Table `plant_best_day(plant_id, day, points jsonb, days, waiting,
   readings_through, computed_at)`, key `(plant_id, day)`. Users can read their own
   plants' rows (via `my_plant`); only a `security definer` function writes them.
   - A nightly pg_cron job writes each plant's row for its local today.
   - A past date is computed on first request by that function, then stored.
   - Recompute when newer readings have landed for the window (recovery or a new
     plant's backfill); never store a `waiting` row as final.
   - Two first requests at once: `insert … on conflict do update`.
3. **Read.** One RPC returns the stored row; a `data.jsx` route and fetch as before.
4. **Fit in the browser.** `chart.jsx` fits the arch from the stored points (about 5,000
   candidates × 288 slots), draws one smooth path, shows its value in the tooltip.
   Time it on a mid-range phone; if it is over 50 ms, fit in the nightly job and store
   the five numbers instead.
5. **Waiting state.** Keep the progress ring; words go through the ui-copy cut-first
   pass.
6. **Widths.** Phone and desktop. The app is dark-only, so one theme.

## Scale

- Nightly job: ~1 s per plant today. 1,000 plants ≈ 17 minutes of DB time, in batches.
  Before that many, feed it from a 5-minute rollup instead of raw minutes (the query
  currently spills to disk).
- Per user: one row read per chart open, fit in the browser.

## Proof

- The fit replayed in a test against a saved export for both plants; must reproduce the
  gaps above within 1 point.
- Tests pass; chart opened on Prince Home in the browser pane at phone and desktop
  width; screenshot.
- `explain analyze` on the stored read and on one nightly compute.

## Bold follow-ups (after it ships)

- **No seasonal lag.** Stretch the curve by how much the day has lengthened since the
  window's middle (sunrise and sunset shifts are in the readings). Clear spring mornings
  currently beat the curve by 2–3%.
- **Day score.** "Today made 84% of a best day" on Overview and each trend day.
- **Panel health alert.** Several clear days in a row well under the curve at usable
  minutes → dirty panels, a failed string, or new shade.
- **Forecast link.** Scale the curve by forecast cloud for a per-plant outlook, replacing
  the single-site clear-sky forecast.
- **Held-back solar, as a range.** Where the battery was full, the gap up to the curve
  suggests solar that was turned away. The curve is a stitched reference and the
  usable-reading rules are a proxy, so this can only ever be a labelled estimate,
  never a kWh figure in the totals (DATA_PIPELINE §7).

## Risks

- Summer shape unmeasured; revisit in December.
- A plant with no battery and capped export is held back with no sign of it; those
  minutes still count and pull the curve down.
- Afternoon depends on few days on plants whose battery fills early.
