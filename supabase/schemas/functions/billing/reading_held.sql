CREATE OR REPLACE FUNCTION billing.reading_held(p_account uuid, p_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select coalesce((select not (st.state in ('trialing', 'active', 'past_due') and not st.must_choose)
                     from billing.account_status(p_account, p_at) st), true)
$function$;
