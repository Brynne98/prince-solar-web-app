CREATE OR REPLACE FUNCTION billing.past_due_cutoff(p_since timestamp with time zone, p_retry_days integer[], p_tz text)
 RETURNS timestamp with time zone
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select (((p_since at time zone p_tz)::date + (select max(d) from unnest(p_retry_days) d) + 2)::timestamp
          at time zone p_tz) - interval '1 millisecond'
$function$;
