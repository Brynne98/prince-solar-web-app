CREATE OR REPLACE FUNCTION billing.price_keeping_offer(p_plan text, p_market text, p_interval text, p_offer text, p_at timestamp with time zone)
 RETURNS billing.prices
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare pr billing.prices;
begin
  if p_offer is not null then pr := billing.price_for(p_plan, p_market, p_interval, p_offer, p_at); end if;
  if pr.id is null then pr := billing.price_for(p_plan, p_market, p_interval, null, p_at); end if;
  if pr.id is null then raise exception 'no price for % %', p_plan, p_interval using errcode = '22023'; end if;
  return pr;
end $function$;
