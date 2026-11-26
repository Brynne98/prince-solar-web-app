CREATE OR REPLACE FUNCTION public.api_grid_today(p_plant bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with p as (select public.my_plant(p_plant) as id),
  z as (
    select p.id, plants.tz(p.id) as tz
      from p
  ),
  lo as (
    select z.id, extract(epoch from coalesce(p_date, (now() at time zone z.tz)::date)::timestamp at time zone z.tz)::bigint as t0,
           least(extract(epoch from (coalesce(p_date, (now() at time zone z.tz)::date) + 1)::timestamp at time zone z.tz)::bigint,
                 extract(epoch from now())::bigint + 60) as t1
      from z
  ),
  m as (
    select g.ts, g.present
      from lo, private.grid_minutes(lo.id, lo.t0, lo.t1) g
  ),
  v as (
    select ((r.ts - lo.t0) / 300)::int as b,
           avg(r.grid_volt_v) filter (where r.grid_volt_v > 100) as volt
      from lo join public.readings r on r.plant_id = lo.id and r.ts >= lo.t0 and r.ts < lo.t1
     group by 1
  ),
  o as (
    select ((m.ts - lo.t0) / 300)::int as b, bool_or(not m.present) as off
      from m, lo
     group by 1
  )
  select jsonb_build_object(
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'i', coalesce(v.b, o.b),
               'v', round(v.volt::numeric, 1),
               'off', coalesce(o.off, false))
             order by coalesce(v.b, o.b))
        from v full join o on o.b = v.b), '[]'::jsonb),
    'offMinutes', (select count(*) from m where not m.present),
    'asOf', extract(epoch from now())::bigint                                    -- 0167
  )
$function$;
