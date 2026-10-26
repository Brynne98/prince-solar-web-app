-- ============================================================================
-- 0105 — api_export over a long range finishes (SOLAR-191).
--
-- 0104 left out a 5-minute row when minutes covered its bucket with a range
-- test against the minutes CTE, run once per 5-minute row. On plant 538820,
-- a year (45,421 minutes, 8,720 five-minute rows) passed the 8 s statement
-- timeout. The minute buckets now go into a set first and the 5-minute rows
-- anti-join on equality (a hash anti join): the same year takes ~0.24 s.
-- Nothing else changes.
-- ============================================================================

create or replace function public.api_export(p_from date, p_to date, p_plant bigint default null)
returns text
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  pid bigint := public.my_plant(p_plant);
  tz  text;
  lo  bigint;
  hi  bigint;
  body text;
begin
  -- SOLAR-104: the Full history check goes here once plans exist.
  if pid is null then
    raise exception 'no plant' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'bad range' using errcode = '22023';
  end if;
  if p_to - p_from > 365 then
    raise exception 'range too long' using errcode = '22023';
  end if;

  tz := public.plant_tz(pid);
  lo := public.day_start_epoch_tz(p_from, tz);
  hi := public.day_start_epoch_tz(p_to + 1, tz);

  with m as (
    select a.ts, a.pv_w::numeric as pv, a.load_w::numeric as home,
           greatest(a.grid_w, 0)::numeric as grid,
           greatest(a.batt_w, 0)::numeric as chg, greatest(-a.batt_w, 0)::numeric as dis,
           a.soc::numeric as soc
      from public.agg_minute a
     where a.plant_id = pid and a.ts >= lo and a.ts < hi
  ),
  mb as (select distinct (m.ts / 300) * 300 as b from m),
  f as (
    select f.ts, f.pv_w_avg::numeric, f.load_w_avg::numeric, f.grid_in_w_avg::numeric,
           f.batt_pos_w_avg::numeric, f.batt_neg_w_avg::numeric, f.soc_avg::numeric
      from public.agg_5m f
     where f.plant_id = pid and f.ts >= lo and f.ts < hi
       and not exists (select 1 from mb where mb.b = f.ts)
  ),
  x as (select * from m union all select * from f)
  select string_agg(
           -- not concat_ws: it drops a null and shifts the columns left
           to_char(public.local_ts_tz(x.ts, tz), 'YYYY-MM-DD HH24:MI')
             || ',' || coalesce(round(x.pv)::text, '') || ',' || coalesce(round(x.home)::text, '')
             || ',' || coalesce(round(x.grid)::text, '') || ',' || coalesce(round(x.chg)::text, '')
             || ',' || coalesce(round(x.dis)::text, '') || ',' || coalesce(round(x.soc)::text, ''),
           e'\n' order by x.ts)
    into body
    from x;

  return 'Time,Solar (W),Home (W),From grid (W),Battery charging (W),Battery discharging (W),Battery (%)'
         || e'\n' || coalesce(body || e'\n', '');
end $$;
