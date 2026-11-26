CREATE OR REPLACE FUNCTION public.q_grid_feed_scale(p_plant bigint)
 RETURNS double precision
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with n as (
    select count(distinct sn) as inv,
           count(distinct sn) filter (where grid_import_total_kwh > 0) as ct
      from public.readings
     where plant_id = p_plant and ts >= extract(epoch from now())::bigint - 3 * 86400
  )
  select case when inv > 0 and ct > 0 then inv::double precision / ct else 1 end from n
$function$;
