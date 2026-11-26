CREATE OR REPLACE FUNCTION private.history_fence()
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'pg_temp'
AS $function$
  select pg_advisory_xact_lock_shared(8, 659)
$function$;
