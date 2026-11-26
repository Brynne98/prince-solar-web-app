CREATE OR REPLACE FUNCTION billing.pay_now(p_account uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare st billing.status; s billing.subscriptions;
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.sub is null or st.state not in ('active', 'past_due') then raise exception 'nothing to pay' using errcode = '22023'; end if;
  select * into s from billing.subscriptions where id = st.sub;
  if s.period_end > p_at then raise exception 'nothing to pay' using errcode = '22023'; end if;
  return billing.invoice_out(billing.ensure_renewal(s.id, p_at));
end $function$;
