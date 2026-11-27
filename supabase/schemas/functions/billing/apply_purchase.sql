CREATE OR REPLACE FUNCTION billing.apply_purchase(p_inv billing.invoices, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  m billing.markets;
  sid uuid;
  day int;
  pe timestamptz;
  had bigint[];
  restart boolean;
  old billing.subscriptions;
  tz text;
begin
  select mk.* into m from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = p_inv.account;
  tz := coalesce((select a.time_zone from billing.accounts a where a.id = p_inv.account), m.default_time_zone);
  restart := (billing.account_status(p_inv.account, p_at)).state = 'ended';
  old := billing.live_sub(p_inv.account);
  if old.id is not null then
    if old.cancel_at_period_end and old.period_end <= p_at then
      perform billing.end_sub(old.id, old.period_end, 'cancelled', p_at, 'paystack', false);
    else
      perform billing.end_sub(old.id, coalesce(billing.past_due_cutoff(old.past_due_since, m.retry_days, tz), p_at),
                              'unpaid', p_at, 'paystack', false);
    end if;
  end if;
  day := extract(day from p_at at time zone m.default_time_zone)::int;
  pe := billing.add_period(p_at, p_inv.interval, day, m.default_time_zone);
  insert into billing.subscriptions (account, price, plan, currency, interval, amount_minor, extra_place_minor,
                                     extra_places, offer, status, started_at, billing_day, period_start, period_end)
  values (p_inv.account, p_inv.price, p_inv.plan, p_inv.currency, p_inv.interval, p_inv.plan_amount_minor,
          p_inv.extra_place_minor, p_inv.extra_places, p_inv.offer, 'active', p_at, day, p_at, pe)
  returning id into sid;
  update billing.invoices set subscription = sid, period_start = p_at, period_end = pe where id = p_inv.id;
  -- paying in the free week ends the week and starts billing that day
  update billing.accounts set trial_ends_at = least(trial_ends_at, p_at)
   where id = p_inv.account and trial_started_at is not null;
  had := array(select plant from billing.seats where account = p_inv.account and closed_at is null);
  perform billing.lock_plants(p_inv.plants || had);
  perform billing.write_seats(p_inv.account, p_inv.plants, p_at);
  if restart then
    perform billing.request_history(p_inv.account, array(select x from unnest(p_inv.plants) x where x = any (had)), p_at, false, 'restart');
  end if;
end $function$;
