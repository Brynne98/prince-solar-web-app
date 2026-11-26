CREATE OR REPLACE FUNCTION public.api_data_days(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;
