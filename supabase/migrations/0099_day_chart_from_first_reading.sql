-- ============================================================================
-- 0099 — the day chart draws from the first reading of the day. (SOLAR-178)
--
-- api_history sent an empty series while a day had 5 or fewer five-minute buckets,
-- so the first ~25 minutes after midnight were blank. The old Express server used
-- that test to spot days from before logging began and drew SunSynk's own feed for
-- them; the port to Supabase (5 Aug) kept the test and dropped the feed. Now only a
-- day with no buckets at all is empty ('approx' still marks that case). Body as live
-- (0028) apart from that one test.
--
-- api_data_days (0098) used the same test; a day now counts from its first bucket.
-- ============================================================================

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
$function$

;

create or replace function public.api_data_days(p_plant bigint default null)
returns jsonb
language sql
stable
security definer
set search_path to public, pg_temp
as $fn$
  with pl as (select public.my_plant(p_plant) as id),
  tz as (select public.plant_tz((select id from pl)) as tz),
  b as (
    select a.ts / 300 as k from public.agg_minute a where a.plant_id = (select id from pl)
    union
    select f.ts / 300 from public.agg_5m f where f.plant_id = (select id from pl)
  ),
  days as (
    select distinct public.local_ts_tz(b.k * 300, (select tz from tz))::date as d from b
  )
  select coalesce(jsonb_agg(to_char(d, 'YYYY-MM-DD') order by d), '[]'::jsonb) from days
$fn$;

revoke all on function public.api_data_days(bigint) from public, anon;
grant execute on function public.api_data_days(bigint) to authenticated, service_role;
