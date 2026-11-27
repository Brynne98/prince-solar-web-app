CREATE OR REPLACE FUNCTION history.clean(p_at timestamp with time zone DEFAULT now())
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  delete from history.days where status <> 'queued' and closed_at < p_at - interval '7 days';
  delete from history.imports where status <> 'open' and finished_at < p_at - interval '30 days';
  delete from history.calls where minute < p_at - interval '1 day';
$function$;
