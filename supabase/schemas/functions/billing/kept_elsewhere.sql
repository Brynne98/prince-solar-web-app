CREATE OR REPLACE FUNCTION billing.kept_elsewhere(p_account uuid, p_plant bigint, p_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare se record; st billing.status;
begin
  for se in select s.account from billing.seats s
             where s.plant = p_plant and s.account <> p_account and s.closed_at is null loop
    st := billing.account_status(se.account, p_at);
    if st.state in ('trialing', 'active', 'past_due') then return true; end if;
    if st.state = 'ended' and st.access_ended_at + make_interval(days => st.retention_days) > p_at then return true; end if;
  end loop;
  return false;
end $function$;
