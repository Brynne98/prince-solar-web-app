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
