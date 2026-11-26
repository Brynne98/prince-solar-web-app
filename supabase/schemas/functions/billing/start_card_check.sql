CREATE OR REPLACE FUNCTION billing.start_card_check(p_account uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare a billing.accounts; m billing.markets; inv billing.invoices; st billing.status;
begin
  a := billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.sub is not null and st.state in ('active', 'past_due')
     and (select period_end from billing.subscriptions where id = st.sub) <= p_at then
    return billing.invoice_out(billing.ensure_renewal(st.sub, p_at));
  end if;
  select * into m from billing.markets where code = a.market;
  insert into billing.invoices (account, kind, amount_minor, currency, created_at)
  values (p_account, 'card_check', m.min_charge_minor, m.currency, p_at) returning * into inv;
  return billing.invoice_out(inv);
end $function$;
