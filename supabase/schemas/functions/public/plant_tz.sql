CREATE OR REPLACE FUNCTION public.plant_tz(p_plant bigint)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$ select coalesce((select timezone from public.plant_config where plant_id = p_plant), 'Africa/Johannesburg') $function$;
