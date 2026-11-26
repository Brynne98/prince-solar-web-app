CREATE OR REPLACE FUNCTION public.gap_record(p_plant bigint, p_from bigint, p_to bigint)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  insert into private.gaps (plant_id, from_ts, to_ts) values (p_plant, p_from, p_to)
  on conflict (plant_id, from_ts) do nothing
$function$;
