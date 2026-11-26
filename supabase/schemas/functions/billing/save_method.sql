CREATE OR REPLACE FUNCTION billing.save_method(p_account uuid, p_tx jsonb, p_at timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  au jsonb := p_tx->'authorization';
  reusable boolean := coalesce((p_tx->'authorization'->>'reusable')::boolean, false);
  pm_id uuid;
begin
  if p_account is null or au is null or au->>'authorization_code' is null then return null; end if;
  insert into billing.payment_methods (account, provider, customer_code, auth_ref, auth_email, reusable, signature,
                                       card_type, last4, exp_month, exp_year, active, disabled_reason, created_at)
  values (p_account, 'paystack', p_tx->'customer'->>'customer_code', au->>'authorization_code', p_tx->'customer'->>'email',
          reusable, au->>'signature', btrim(au->>'card_type'), au->>'last4', nullif(au->>'exp_month', '')::smallint,
          nullif(au->>'exp_year', '')::smallint, false, case when reusable then 'replaced' else 'not_reusable' end, p_at)
  on conflict (provider, auth_ref) do update
     set auth_email = coalesce(excluded.auth_email, payment_methods.auth_email),
         customer_code = coalesce(excluded.customer_code, payment_methods.customer_code)
  returning payment_methods.id into pm_id;
  if reusable then
    update billing.payment_methods set active = false, disabled_reason = 'replaced'
     where account = p_account and active and payment_methods.id <> pm_id;
    update billing.payment_methods set active = true, disabled_reason = null, account = p_account,
                                       activated_at = case when active then activated_at else p_at end
     where payment_methods.id = pm_id;
  end if;
  return pm_id;
end $function$;
