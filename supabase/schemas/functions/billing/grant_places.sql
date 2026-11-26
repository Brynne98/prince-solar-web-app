CREATE OR REPLACE FUNCTION billing.grant_places(p_account uuid, p_at timestamp with time zone)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select coalesce(sum(places), 0)::int from billing.grants
   where account = p_account and starts_at <= p_at and (ends_at is null or ends_at > p_at)
$function$;
