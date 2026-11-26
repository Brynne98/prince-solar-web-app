CREATE OR REPLACE FUNCTION public.q_day_agg(p_plant bigint, p_day date, p_source text DEFAULT NULL::text)
 RETURNS TABLE(hm text, pv_w numeric, load_w numeric, batt_w numeric, grid_w numeric, soc numeric, feed_n bigint, row_n bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pz as (select public.plant_tz(p_plant) as tz),
  b as (select public.day_start_epoch_tz(p_day, (select tz from pz)) as lo),
  m as (
    select (a.ts - b.lo) / 300 as k,
           min(a.ts) as t,
           round(avg(a.pv_w)::numeric)   as pv_w,
           round(avg(a.load_w)::numeric) as load_w,
           round(avg(a.batt_w)::numeric) as batt_w,
           round(avg(a.grid_w)::numeric) as grid_w,
           round(avg(a.soc)::numeric)    as soc,
           sum(case when coalesce(a.source, 'poller') <> 'poller' then 1 else 0 end) as feed_n,
           count(*) as row_n
      from public.agg_minute a, b
     where a.plant_id = p_plant
       and a.ts >= b.lo and a.ts < b.lo + 86400
       and (p_source is null or a.source = p_source)
     group by (a.ts - b.lo) / 300
  ),
  f as (
    select (f.ts - b.lo) / 300 as k, f.ts as t,
           round(f.pv_w_avg::numeric), round(f.load_w_avg::numeric), round(f.batt_w_avg::numeric),
           round(f.grid_w_avg::numeric), round(f.soc_avg::numeric),
           (f.n - f.n_poller)::bigint, f.n::bigint
      from public.agg_5m f, b
     where f.plant_id = p_plant
       and f.ts >= b.lo and f.ts < b.lo + 86400
       and p_source is null          -- a 5-minute row mixes sources; every caller passes null
       and not exists (select 1 from m where m.k = (f.ts - b.lo) / 300)
  )
  select to_char(public.local_ts_tz(x.t, (select tz from pz)), 'HH24:MI'),
         x.pv_w, x.load_w, x.batt_w, x.grid_w, x.soc, x.feed_n, x.row_n
    from (select * from m union all select * from f) x
   order by x.t
$function$;
