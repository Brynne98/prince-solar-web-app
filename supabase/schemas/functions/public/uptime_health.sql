CREATE OR REPLACE FUNCTION public.uptime_health()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select jsonb_build_object('job_check_minutes',
           (select floor(extract(epoch from now() - at) / 60)::int from private.job_check_mark));
$function$;
