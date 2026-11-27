-- SOLAR-692: past days didn't load (v0.66.0). 0283 added the R23 figure functions; the default
-- privileges keep a new function from signed-in users, and two invoker functions they run call
-- them: _energy_row (api_energy, api_trends_daily) calls independence_pct, q_grid_present calls
-- grid_live. Both are pure arithmetic on their arguments (immutable, no table read, empty
-- search_path), so the grant shows nothing; a definer caller would widen what reads it.
grant execute on function public.independence_pct(double precision, double precision) to authenticated;
grant execute on function public.grid_live(double precision) to authenticated;
