CREATE OR REPLACE FUNCTION billing.report_wanted(p_account uuid, p_plant bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select coalesce((billing.account_status(p_account, now())).state, 'none') in ('trialing', 'active', 'past_due')
     and (p_plant is null
          or (exists (select 1 from billing.seats s where s.account = p_account and s.plant = p_plant and s.closed_at is null)
              and billing.has_route(p_account, p_plant, false)))
$function$;
