CREATE OR REPLACE FUNCTION private.billing_offer_drop()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  new.offer_id := null;
  new.offer_until := null;
  return new;
end $function$;
