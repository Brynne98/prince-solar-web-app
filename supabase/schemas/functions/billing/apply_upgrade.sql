CREATE OR REPLACE FUNCTION billing.apply_upgrade(p_inv billing.invoices, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  s billing.subscriptions;
  a billing.accounts;
  np billing.prices;
  had bigint[];
  m billing.markets;
  day int;
begin
  select * into s from billing.subscriptions where id = p_inv.subscription;
  select * into a from billing.accounts where id = p_inv.account;
  -- a booked interval switch carries over to the new plan; a booked downgrade is cleared
  if s.next_price is not null then
    select * into np from billing.prices where id = s.next_price;
    if np.interval <> s.interval then
      np := billing.price_keeping_offer(p_inv.plan, a.market, np.interval, s.offer, p_at);
    else
      np := null;
    end if;
  end if;
  update billing.subscriptions
     set price = p_inv.price, plan = p_inv.plan, amount_minor = p_inv.plan_amount_minor,
         extra_place_minor = p_inv.extra_place_minor, extra_places = p_inv.extra_places,
         next_price = np.id, next_extra_places = null, version = version + 1
   where id = s.id;
  -- the interval the move was made at, from the billing date (0279): it wins over a switch
  -- booked earlier
  if p_inv.next_interval is not null and p_inv.interval = s.interval then
    update billing.subscriptions
       set next_price = case when p_inv.next_interval <> s.interval
                             then (billing.price_keeping_offer(p_inv.plan, a.market, p_inv.next_interval, s.offer, p_at)).id end
     where id = s.id;
  end if;
  -- another interval now: an old monthly-to-yearly charge (copy_from_old) pays the same plan a
  -- year past its billing date; a bigger plan monthly to yearly (0279, and copy_from_old) runs
  -- yearly from the payment, on a new billing day
  if p_inv.interval is distinct from s.interval then
    select mk.* into m from billing.markets mk where mk.code = a.market;
    day := extract(day from p_at at time zone m.default_time_zone)::int;
    update billing.subscriptions
       set interval = p_inv.interval, next_price = null,
           billing_day = case when p_inv.plan = s.plan then s.billing_day else day end,
           period_start = case when p_inv.plan = s.plan then s.period_start else p_at end,
           period_end = case when p_inv.plan = s.plan
                             then billing.add_period(s.period_end, p_inv.interval, s.billing_day, m.default_time_zone)
                             else billing.add_period(p_at, p_inv.interval, day, m.default_time_zone) end
     where id = s.id
    returning * into s;
    -- the bill names the period it bought, for the receipt and a later reversal
    update billing.invoices set period_start = s.period_start, period_end = s.period_end where id = p_inv.id;
  end if;
  update billing.seats set drop_at_period_end = false where account = p_inv.account and closed_at is null and drop_at_period_end;
  had := array(select plant from billing.seats where account = p_inv.account and closed_at is null);
  perform billing.lock_plants(p_inv.plants || had);
  perform billing.write_seats(p_inv.account, p_inv.plants, p_at);
end $function$;
