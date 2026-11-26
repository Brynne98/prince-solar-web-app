-- ============================================================================
-- 0278 — the day's peak is the top minute, not the top 5-minute average. (SOLAR-676)
--
-- Solar, Home and Grid showed "Peak" from the day series, which is 5-minute averages:
-- Tshigabe 2026-11-25 read 9.37 kW at 08:50 while the minutes peaked at 11.58 kW at 14:02.
-- q_day_peak returns the day's top solar, home and grid-import power and their times from
-- agg_minute. A 5-minute bucket with no minute rows (past the 31-day minute retention) uses
-- agg_5m's own max for it, which is the top minute of that bucket, timed to the bucket.
-- Ties go to the earliest. api_history sends it as 'peak'; body otherwise as 0099.
-- ============================================================================

create or replace function public.q_day_peak(p_plant bigint, p_day date)
returns jsonb
language sql
stable
set search_path to public, pg_temp
as $function$
  with pz as (select public.plant_tz(p_plant) as tz),
  b as (select public.day_start_epoch_tz(p_day, (select tz from pz)) as lo),
  m as (
    select a.ts, a.pv_w::real as pv, a.load_w::real as ld, a.grid_w::real as gr
      from public.agg_minute a, b
     where a.plant_id = p_plant and a.ts >= b.lo and a.ts < b.lo + 86400
  ),
  f as (
    select f.ts, f.pv_w_max as pv, f.load_w_max as ld, f.grid_w_max as gr
      from public.agg_5m f, b
     where f.plant_id = p_plant and f.ts >= b.lo and f.ts < b.lo + 86400
       and not exists (select 1 from m where (m.ts - b.lo) / 300 = (f.ts - b.lo) / 300)
  ),
  x as (select * from m union all select * from f),
  pk as (
    select 'pv' as k, (select jsonb_build_array(round(pv), ts) from x where pv is not null order by pv desc, ts limit 1) as v
    union all
    select 'load', (select jsonb_build_array(round(ld), ts) from x where ld is not null order by ld desc, ts limit 1)
    union all
    select 'grid', (select jsonb_build_array(round(gr), ts) from x where gr is not null order by gr desc, ts limit 1)
  )
  select coalesce(jsonb_object_agg(pk.k, jsonb_build_object('w', pk.v -> 0,
           'time', to_char(public.local_ts_tz((pk.v ->> 1)::bigint, (select tz from pz)), 'HH24:MI'))), '{}'::jsonb)
    from pk where pk.v is not null
$function$;

revoke all on function public.q_day_peak(bigint, date) from public, anon;
grant execute on function public.q_day_peak(bigint, date) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.api_history(p_date date DEFAULT NULL::date, p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  d as (select coalesce(p_date, public.today_tz((select tz from pz))) as day),
  agg as (
    select (split_part(a.hm, ':', 1)::int) * 12 + (split_part(a.hm, ':', 2)::int / 5) as bkt,
           a.pv_w, a.batt_w, a.grid_w, a.load_w, a.soc, a.feed_n, a.row_n
      from d, public.q_day_agg((select id from pl), d.day, null) a
  ),
  n as (select count(*) as c, coalesce(max(bkt), 0) as mx from agg),
  lastb as (select case when (select day from d) = public.today_tz((select tz from pz)) then (select mx from n) else 287 end as lb),
  buckets as (
    select g.i as bkt, a.pv_w, a.batt_w, a.grid_w, a.load_w, a.soc, a.feed_n, a.row_n
      from lastb, generate_series(0, (select lb from lastb)) as g(i) left join agg a on a.bkt = g.i
  ),
  defs as (select * from (values ('PV','W','pv',1), ('Battery','W','battflip',2), ('Grid','W','grid',3), ('Load','W','load',4), ('SOC','%','soc',5)) as t(label, unit, field, ord))
  select case when (select c from n) = 0
    then jsonb_build_object('date', (select day from d)::text, 'series', '[]'::jsonb, 'approx', true)
    else jsonb_build_object(
      'date', (select day from d)::text,
      'gapMinutes', public.q_day_gap_minutes((select id from pl), (select day from d)),
      'recoveredMinutes', public.q_recovered_minutes((select id from pl), (select day from d)),
      'peak', public.q_day_peak((select id from pl), (select day from d)),
      'series', (select jsonb_agg(ser order by ord) from (
          select f.ord, jsonb_build_object('label', f.label, 'unit', f.unit, 'points', (
            select jsonb_agg(
              jsonb_build_object('time', public._hm(b.bkt), 'value',
                case when b.row_n is null then null
                     when f.field = 'pv' then coalesce(b.pv_w, 0)
                     when f.field = 'battflip' then -coalesce(b.batt_w, 0)
                     when f.field = 'grid' then coalesce(b.grid_w, 0)
                     when f.field = 'load' then coalesce(b.load_w, 0)
                     else b.soc end)
              || case when b.row_n is not null and b.feed_n > 0 and b.feed_n >= b.row_n then jsonb_build_object('est', true) else '{}'::jsonb end
              order by b.bkt) from buckets b)) as ser from defs f) x))
    end
$function$;
