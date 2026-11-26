CREATE OR REPLACE FUNCTION billing.reads_plant(p_account uuid, p_plant bigint, p_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select exists (select 1 from billing.seats s where s.account = p_account and s.plant = p_plant
                    and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at))
     and coalesce((select st.state in ('trialing', 'active', 'past_due') and not st.must_choose
                     from billing.account_status(p_account, p_at) st), false)
     and billing.has_route(p_account, p_plant, true)
     and not private.history_deleting(p_plant)                                -- 0277
$function$;
