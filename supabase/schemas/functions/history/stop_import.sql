CREATE OR REPLACE FUNCTION history.stop_import(p_import bigint, p_reason text, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update history.imports set status = 'stopped', stop_reason = p_reason, finished_at = p_at
   where id = p_import and status = 'open';
  update history.days set status = 'dropped', note = p_reason, closed_at = p_at, claim = null, claimed_until = null
   where import = p_import and status = 'queued';
$function$;
