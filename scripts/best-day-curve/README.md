# Best-day curve measurements (14 Sep 2026)

Evidence for `BEST_DAY_CURVE.md`. Read-only against production.

Export (both plants, qualifying per-day 5-minute means). `fit.py`/`fit2.py` read `perday.csv`;
`clear.py`, `two.py`, `why.py` read `perday_all.csv` (the same query, longer window):

```bash
supabase db query --linked -o csv -f scripts/best-day-curve/perday.sql > scripts/best-day-curve/perday_all.csv
```

Delete the CLI's banner lines from the top of the CSV (`Initialising…`, update notice).
Run each script from this folder: `python3 fit2.py` (numpy only).

- `fit.py` — first fit, ends left free (they drift).
- `fit2.py` — ends pinned; 7/10/14/21 days vs the 30-day curve.
- `clear.py` — Prince Home, predicted curve vs clear days, windows 14–60, p75 vs p90.
- `two.py` — one arch vs two arches vs the old per-slot line.
- `why.py` — usable readings by hour; ≥2 vs ≥5 days per slot, lean vs symmetric.
