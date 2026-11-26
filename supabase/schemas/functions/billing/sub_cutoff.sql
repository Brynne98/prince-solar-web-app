CREATE OR REPLACE FUNCTION billing.sub_cutoff(p_sub uuid)
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select coalesce(s.ended_at, billing.past_due_cutoff(s.past_due_since, m.retry_days, coalesce(a.time_zone, m.default_time_zone)))
    from billing.subscriptions s join billing.accounts a on a.id = s.account join billing.markets m on m.code = a.market
   where s.id = p_sub
$function$;
