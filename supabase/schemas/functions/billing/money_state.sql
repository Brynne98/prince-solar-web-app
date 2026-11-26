CREATE OR REPLACE FUNCTION billing.money_state(p_account uuid, p_at timestamp with time zone, p_state text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  pm billing.payment_methods;
  s billing.subscriptions;
  np billing.prices;
  owed int;
  dispute boolean;
  due billing.invoices;
  url text;
  tz text;
begin
  pm := billing.active_method(p_account);
  select mk.default_time_zone into tz from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = p_account;
  owed := (select coalesce(sum(amount_owed_minor), 0) from billing.invoices where account = p_account);
  dispute := exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
                      where i.account = p_account and pa.dispute_open);
  -- a row the clock has ended (the job not run yet) is no running plan
  if p_state in ('active', 'past_due') then s := billing.live_sub(p_account); end if;
  if s.id is not null then
    if s.next_price is not null then select * into np from billing.prices where id = s.next_price; end if;
    select * into due from billing.invoices
     where subscription = s.id and kind = 'renewal' and status = 'open' order by created_at desc limit 1;
    select pay_url into url from billing.payment_attempts
     where invoice = due.id and status = 'pending' and pay_url is not null and replaced_at is null
     order by created_at desc limit 1;
  end if;
  return jsonb_build_object(
    'card', case when pm.id is not null then jsonb_build_object('last4', pm.last4, 'exp_month', pm.exp_month,
                                                                 'exp_year', pm.exp_year, 'card_type', pm.card_type) end,
    'card_expires_first', coalesce(pm.id is not null and s.id is not null and not s.cancel_at_period_end
                          and (make_date(pm.exp_year::int, pm.exp_month::int, 1) + interval '1 month')::timestamp
                              at time zone tz <= s.period_end, false),
    'next_plan', case when s.id is not null and not s.cancel_at_period_end then coalesce(np.plan, s.plan) end,
    'next_interval', case when s.id is not null and not s.cancel_at_period_end then coalesce(np.interval, s.interval) end,
    'next_amount_minor', case when s.id is not null and not s.cancel_at_period_end then
                           coalesce(np.amount_minor, s.amount_minor)
                           + coalesce(s.next_extra_places, s.extra_places) * coalesce(np.extra_place_minor, s.extra_place_minor) end,
    'amount_due_minor', due.amount_minor,
    'pay_url', url,
    'owed_minor', owed,
    'dispute_open', dispute,
    'may_delete', p_state in ('none', 'trialing', 'ended') and owed = 0 and not dispute)
    -- past due with no card to charge: no retry or charge date to promise
    || case when p_state = 'past_due' and pm.id is null
            then jsonb_build_object('next_retry_at', null, 'next_charge_at', null) else '{}'::jsonb end;
end $function$;
