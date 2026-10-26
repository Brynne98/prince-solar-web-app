-- ============================================================================
-- 0104 — Download your data (SOLAR-191).
--
-- api_export(from, to, plant) returns the plant's readings for whole local days
-- from..to (inclusive) as one CSV text: every minute that agg_minute still holds
-- (31 days, 0082), every 5 minutes from agg_5m before that. A 5-minute bucket is
-- left out when the same bucket has minutes, as in q_day_agg.
--
-- One text value, not a set of rows: PostgREST caps a set at max_rows (1,000).
-- 366 days at most, so a file stays under ~5 MB.
--
-- Columns are watts, not kWh. Battery is split by agg_minute's sign: + is
-- charging (batt_sign_detect settles it per plant). Grid is what came in;
-- these plants don't export.
--
-- Definer, like api_balance (0066): reads only the caller's plant through
-- my_plant(), without RLS on every row.
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
  f as (
    select f.ts, f.pv_w_avg::numeric, f.load_w_avg::numeric, f.grid_in_w_avg::numeric,
           f.batt_pos_w_avg::numeric, f.batt_neg_w_avg::numeric, f.soc_avg::numeric
      from public.agg_5m f
     where f.plant_id = pid and f.ts >= lo and f.ts < hi
       and not exists (select 1 from m where m.ts >= f.ts and m.ts < f.ts + 300)
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

revoke all on function public.api_export(date, date, bigint) from public, anon;
grant execute on function public.api_export(date, date, bigint) to authenticated, service_role;
