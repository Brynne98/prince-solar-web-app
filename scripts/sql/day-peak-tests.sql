-- The day's peak (SOLAR-676, 0278): the top minute from agg_minute, not the top 5-minute
-- average; a bucket with no minute rows uses agg_5m's max for it. Ties go to the earliest.
-- Needs the local database at the latest migration. Runs in one transaction, rolled back.
-- Exit code decides: any wrong case raises.
\set ON_ERROR_STOP 1
begin;
-- made-up readings for a plant nobody is linked to: past the plant_row_guard trigger
set local session_replication_role = replica;
create temp table t(step text, got text, want text);
do $$
declare
  p bigint := 990676;
  d1 date := '2026-01-10'; d2 date := '2026-01-11';
  lo1 bigint := public.day_start_epoch_tz(d1, 'Africa/Johannesburg');
  lo2 bigint := public.day_start_epoch_tz(d2, 'Africa/Johannesburg');
  at1 bigint;
  pk jsonb;
begin
  -- day 1, minutes: a steady 9 kW from 08:50 to 08:54 (the top 5-minute average), one
  -- 11.58 kW minute at 14:02 in a bucket otherwise at 1 kW; home 5 kW at 10:50 and at 12:00
  insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
  select p, lo1 + (8 * 60 + 50 + i) * 60, 9000, 1000, 0, 0, 50, 'poller' from generate_series(0, 4) i;
  insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
  select p, lo1 + (14 * 60 + i) * 60, case when i = 2 then 11580 else 1000 end, 1000, 0, 0, 50, 'poller' from generate_series(0, 4) i;
  insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source) values
    (p, lo1 + (10 * 60 + 50) * 60, 500, 5000, 0, 3000, 50, 'poller'),
    (p, lo1 + (12 * 60) * 60, 500, 5000, 0, 100, 50, 'poller');
  -- day 1, 5-minute rows: one for the 14:00 bucket the minutes cover (ignored), one at
  -- 03:00 with no minutes (counts: its grid max beats every minute)
  insert into public.agg_5m (plant_id, ts, n, n_poller, pv_w_avg, pv_w_max, load_w_avg, load_w_max, grid_w_avg, grid_w_max) values
    (p, lo1 + 14 * 3600, 5, 5, 3116, 99999, 1000, 99999, 0, 99999),
    (p, lo1 + 3 * 3600, 5, 5, 0, 0, 800, 900, 2000, 4000);

  pk := public.q_day_peak(p, d1);
  insert into t values ('solar is the top minute', pk #>> '{pv,w}' || ' at ' || (pk #>> '{pv,time}'), '11580 at 14:02');
  insert into t values ('home tie goes to the earliest', pk #>> '{load,w}' || ' at ' || (pk #>> '{load,time}'), '5000 at 10:50');
  insert into t values ('grid from a 5-minute-only bucket', pk #>> '{grid,w}' || ' at ' || (pk #>> '{grid,time}'), '4000 at 03:00');
  insert into t values ('api_history sends it', ((public.api_history(d1, p) -> 'peak') = pk)::text, 'true');

  -- day 2, past the minute retention: 5-minute rows only; the top max wins, not the top average
  insert into public.agg_5m (plant_id, ts, n, n_poller, pv_w_avg, pv_w_max, load_w_avg, load_w_max, grid_w_avg, grid_w_max) values
    (p, lo2 + 9 * 3600, 5, 5, 5000, 7000, 400, 600, -10, 20),
    (p, lo2 + 12 * 3600 + 1800, 5, 5, 6000, 6500, 700, 1200, -20, -5);
  pk := public.q_day_peak(p, d2);
  insert into t values ('old day: solar from the 5-minute max', pk #>> '{pv,w}' || ' at ' || (pk #>> '{pv,time}'), '7000 at 09:00');
  insert into t values ('old day: home from the 5-minute max', pk #>> '{load,w}' || ' at ' || (pk #>> '{load,time}'), '1200 at 12:30');

  -- a day with nothing: no peak, and api_history keeps its empty answer
  insert into t values ('empty day', public.q_day_peak(p, '2026-01-12')::text, '{}');
  insert into t values ('empty day api_history has no peak', (public.api_history('2026-01-12', p) ? 'peak')::text, 'false');
end $$;
select step, got, want, case when got is not distinct from want then 'ok' else 'WRONG' end as result from t;
do $$ begin
  if exists (select 1 from t where got is distinct from want) then raise exception 'day-peak tests failed'; end if;
  raise notice 'all % checks passed', (select count(*) from t);
end $$;
rollback;
