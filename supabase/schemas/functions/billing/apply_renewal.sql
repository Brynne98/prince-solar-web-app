CREATE OR REPLACE FUNCTION billing.apply_renewal(p_inv billing.invoices, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare dropped bigint[];
begin
  update billing.subscriptions
     set status = 'active', past_due_since = null, ended_at = null, price = p_inv.price, plan = p_inv.plan, interval = p_inv.interval,
         amount_minor = p_inv.plan_amount_minor, extra_place_minor = p_inv.extra_place_minor,
         extra_places = p_inv.extra_places, period_start = p_inv.period_start, period_end = p_inv.period_end,
         next_price = null, next_extra_places = null, version = version + 1
   where id = p_inv.subscription;
  -- a booked downgrade: the plants picked to drop go now
  dropped := array(select plant from billing.seats
                    where account = p_inv.account and closed_at is null and drop_at_period_end order by plant);
  if cardinality(dropped) > 0 then
    perform billing.lock_plants(dropped);
    update billing.seats set closed_at = p_at, close_reason = 'dropped', drop_at_period_end = false
     where account = p_inv.account and closed_at is null and drop_at_period_end;
    perform plants.bump(dropped);
  end if;
end $function$;
