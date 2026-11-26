CREATE OR REPLACE FUNCTION public.inverters_list()
 RETURNS TABLE(sn text, plant_id bigint)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$ select sn, plant_id from private.inverters order by sn $function$;
