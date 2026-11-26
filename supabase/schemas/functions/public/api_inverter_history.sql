CREATE OR REPLACE FUNCTION public.api_inverter_history(p_date date DEFAULT NULL::date, p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  d as (select coalesce(p_date, public.today_tz((select tz from pz))) as day),
  lo as (select public.day_start_epoch_tz((select day from d), (select tz from pz)) as t0),
  raw as (
    select t.sn, ((t.ts - (select t0 from lo)) / 300)::int as bkt, t.ts, t.ac_c, t.dc_c, t.vac_v, t.fac_hz, t.grid_fac_hz
      from public.inverter_history t, lo
     where t.plant_id = (select id from pl) and t.ts >= lo.t0 and t.ts < lo.t0 + 86400
  ),
  fromraw as (
    select sn, bkt, count(*)::int as n, count(dc_c)::int as dcn,
           max(ac_c) as ac, max(dc_c) as dc, min(dc_c) as dcmin,
           min(vac_v) as vmin, max(vac_v) as vmax,
           (array_agg(vac_v order by ts desc) filter (where vac_v is not null))[1] as v,
           min(fac_hz) as fmin, max(fac_hz) as fmax,
           min(grid_fac_hz) as gmin, max(grid_fac_hz) as gmax
      from raw group by sn, bkt
  ),
  b as (
    select * from fromraw
    union all
    select f.sn, ((f.ts - (select t0 from lo)) / 300)::int, f.n::int, case when f.dc_max is null then 0 else f.n::int end,
           f.ac_max, f.dc_max, f.dc_min, f.vac_min, f.vac_max, f.vac_last,
           f.fac_min, f.fac_max, f.gfac_min, f.gfac_max
      from public.inverter_history_5m f, lo
     where f.plant_id = (select id from pl) and f.ts >= lo.t0 and f.ts < lo.t0 + 86400
       and not exists (select 1 from fromraw r
                        where r.sn = f.sn and r.bkt = ((f.ts - lo.t0) / 300)::int)
  ),
  sns as (
    select r.sn, coalesce(nullif(m.alias, ''), r.sn) as alias
      from (select distinct sn from b) r left join plants.meta_info m on m.sn = r.sn
  )
  select jsonb_build_object(
    'date', (select day from d)::text,
    'inverters', coalesce((select jsonb_agg(jsonb_build_object(
        'sn', s.sn, 'alias', s.alias,
        'dcFlat', (select sum(x.dcn) > 1 and min(x.dcmin) = max(x.dc) from b x where x.sn = s.sn),
        'last', (select public._hm(max(bkt)) from b x where x.sn = s.sn),
        'points', (select jsonb_agg(jsonb_build_object('time', public._hm(g.i),
                     'ac', x.ac, 'dc', x.dc, 'vmin', x.vmin, 'vmax', x.vmax, 'v', x.v,
                     'fmin', x.fmin, 'fmax', x.fmax, 'gmin', x.gmin, 'gmax', x.gmax) order by g.i)
                     from generate_series(0, 287) g(i) left join b x on x.sn = s.sn and x.bkt = g.i)
      ) order by s.alias) from sns s), '[]'::jsonb))
$function$;
