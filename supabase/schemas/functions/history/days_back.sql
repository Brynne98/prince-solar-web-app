CREATE OR REPLACE FUNCTION history.days_back()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select history.setting('HISTORY_DAYS', 60)
$function$;
