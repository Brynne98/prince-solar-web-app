CREATE OR REPLACE FUNCTION public.q_day_peak(p_plant bigint, p_day date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
