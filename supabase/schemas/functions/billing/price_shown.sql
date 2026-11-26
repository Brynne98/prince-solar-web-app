CREATE OR REPLACE FUNCTION billing.price_shown(p_account uuid, p_plan text, p_interval text, p_at timestamp with time zone)
 RETURNS billing.prices
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a billing.accounts;
  s billing.subscriptions;
  pr billing.prices;
  off text;
begin
  select * into a from billing.accounts where id = p_account;
  if (billing.account_status(p_account, p_at)).sub is not null then
    s := billing.live_sub(p_account);
    return billing.price_keeping_offer(p_plan, a.market, p_interval, s.offer, p_at);
  end if;
  off := billing.offer_for(p_account, p_at);
  if off is not null then pr := billing.price_for(p_plan, a.market, p_interval, off, p_at); end if;
  if pr.id is null then pr := billing.price_for(p_plan, a.market, p_interval, null, p_at); end if;
  return pr;
end $function$;
