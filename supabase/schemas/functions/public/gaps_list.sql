CREATE OR REPLACE FUNCTION public.gaps_list()
 RETURNS TABLE(plant_id bigint, from_ts bigint, to_ts bigint)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$ select plant_id, from_ts, to_ts from private.gaps order by plant_id, from_ts $function$;
