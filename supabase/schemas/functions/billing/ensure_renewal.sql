CREATE OR REPLACE FUNCTION billing.ensure_renewal(p_sub uuid, p_at timestamp with time zone)
 RETURNS billing.invoices
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  s billing.subscriptions;
  m billing.markets;
  np billing.prices;
  inv billing.invoices;
  key text;
  iv text;
  extras int;
begin
  select * into s from billing.subscriptions where id = p_sub;
  select mk.* into m from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = s.account;
  key := extract(epoch from s.period_end)::bigint::text;
  select * into inv from billing.invoices
   where subscription = p_sub and kind = 'renewal' and period_key = key and status <> 'void';
  if found then return inv; end if;
  if s.next_price is not null then select * into np from billing.prices where id = s.next_price; end if;
  iv := coalesce(np.interval, s.interval);
  extras := coalesce(s.next_extra_places, s.extra_places);
  insert into billing.invoices (account, subscription, kind, price, plan, interval, offer, extra_places,
                                plan_amount_minor, extra_place_minor, amount_minor, tax_minor, currency,
                                period_start, period_end, period_key, created_at)
  values (s.account, s.id, 'renewal', coalesce(np.id, s.price), coalesce(np.plan, s.plan), iv, s.offer, extras,
          coalesce(np.amount_minor, s.amount_minor), coalesce(np.extra_place_minor, s.extra_place_minor),
          coalesce(np.amount_minor, s.amount_minor) + extras * coalesce(np.extra_place_minor, s.extra_place_minor),
          np.tax_minor, s.currency,
          s.period_end, billing.add_period(s.period_end, iv, s.billing_day, m.default_time_zone), key, p_at)
  returning * into inv;
  return inv;
end $function$;
