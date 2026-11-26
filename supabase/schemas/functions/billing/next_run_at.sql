CREATE OR REPLACE FUNCTION billing.next_run_at(p_from timestamp with time zone)
 RETURNS timestamp with time zone
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select case when (p_from at time zone 'UTC')::time < time '04:00'
                then ((p_from at time zone 'UTC')::date + time '04:00') at time zone 'UTC'
              when (p_from at time zone 'UTC')::time <= time '05:55' then p_from
              else ((p_from at time zone 'UTC')::date + 1 + time '04:00') at time zone 'UTC' end
$function$;
