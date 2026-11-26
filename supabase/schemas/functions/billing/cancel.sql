CREATE OR REPLACE FUNCTION billing.cancel(p_account uuid, p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare st billing.status; s billing.subscriptions;
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state <> 'active' or st.sub is null then raise exception 'no running plan to cancel' using errcode = '22023'; end if;
  update billing.subscriptions set cancel_at_period_end = true, version = version + 1
   where id = st.sub and not cancel_at_period_end returning * into s;
  if found then
    perform billing.bump(p_account);
    perform billing.log_event(p_account, p_at, p_actor, 'cancel', null, jsonb_build_object('ends', s.period_end));
  end if;
  return billing.account_state(p_account, p_at);
end $function$;
