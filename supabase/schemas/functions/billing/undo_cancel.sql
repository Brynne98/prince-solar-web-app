CREATE OR REPLACE FUNCTION billing.undo_cancel(p_account uuid, p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare st billing.status; s billing.subscriptions;
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state <> 'active' or st.cancel_at is null then raise exception 'no cancel to undo' using errcode = '22023'; end if;
  update billing.subscriptions set cancel_at_period_end = false, version = version + 1 where id = st.sub returning * into s;
  perform billing.bump(p_account);
  perform billing.log_event(p_account, p_at, p_actor, 'undo_cancel', null, jsonb_build_object('next_charge', s.period_end));
  return billing.account_state(p_account, p_at);
end $function$;
