CREATE OR REPLACE FUNCTION private.history_deleting(p_plant bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  select exists (select 1 from private.history_delete_queue where plant_id = p_plant)
$function$;
