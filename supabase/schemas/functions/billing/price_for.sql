CREATE OR REPLACE FUNCTION billing.price_for(p_plan text, p_market text, p_interval text, p_offer text, p_at timestamp with time zone)
 RETURNS billing.prices
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select * from billing.prices
   where plan = p_plan and market = p_market and interval = p_interval and offer is not distinct from p_offer
     and active_from <= p_at and (active_until is null or active_until > p_at)
   order by active_from desc limit 1
$function$;
