CREATE OR REPLACE FUNCTION public.live_plants()
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select distinct r.plant from billing.reading_routes(now()) r
$function$;
