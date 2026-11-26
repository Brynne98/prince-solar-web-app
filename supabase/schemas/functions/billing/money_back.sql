CREATE OR REPLACE FUNCTION billing.money_back(p_att billing.payment_attempts, p_inv billing.invoices, p_amount integer, p_reason text, p_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  s billing.subscriptions;
  owed int := coalesce(p_amount, p_att.amount_minor);
begin
  if p_inv.account is null or p_inv.kind = 'card_check' then return jsonb_build_object('action', 'recorded'); end if;
  if p_inv.subscription is not null then
    select * into s from billing.subscriptions where id = p_inv.subscription for update;
  end if;
  if s.id is not null and (billing.account_status(p_inv.account, p_at)).sub = s.id
     and p_inv.period_start = s.period_start then
    perform billing.end_sub(s.id, p_at, p_reason, p_at, 'paystack');
    update billing.payment_methods set active = false,
                                       disabled_reason = case when p_reason = 'reversed' then 'reversed' else 'dispute' end
     where id = p_att.payment_method and active;
    return jsonb_build_object('action', 'plan_ended');
  end if;
  update billing.invoices set amount_owed_minor = owed where id = p_inv.id;
  perform billing.bump(p_inv.account);
  perform billing.log_event(p_inv.account, p_at, 'paystack', 'money_owed', null,
                            jsonb_build_object('invoice', p_inv.id, 'amount', owed), p_reason);
  return jsonb_build_object('action', 'owed', 'amount_minor', owed);
end $function$;
