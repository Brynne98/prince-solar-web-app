CREATE OR REPLACE FUNCTION billing.offer_first_time_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  if new.offer is not null
     and exists (select 1 from billing.offers o where o.code = new.offer and o.first_time_only)
     and exists (select 1 from billing.subscriptions s where s.account = new.account and s.id <> new.id) then
    raise exception 'the launch price is for first-time members only' using errcode = '22023';
  end if;
  return new;
end $function$;
