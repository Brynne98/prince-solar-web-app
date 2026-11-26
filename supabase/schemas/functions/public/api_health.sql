CREATE OR REPLACE FUNCTION public.api_health(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with s as (
    select max(ts) as last_ts from public.agg_minute
     where p_plant is null or plant_id = public.my_plant(p_plant)
  ),
  a as (
    select s.last_ts,
           s.last_ts is null
           or (extract(epoch from now())::bigint - s.last_ts) > 900 as stale
      from s
  )
  select case when p_plant is null
    then jsonb_build_object('stale', a.stale)
    else jsonb_build_object(
      'lastTs', a.last_ts,
      'ageSeconds', case when a.last_ts is null then null
                         else extract(epoch from now())::bigint - a.last_ts end,
      'stale', a.stale,
      'expectedIntervalSeconds', 60,
      'scope', 'plant')
  end
  from a
$function$;
