CREATE OR REPLACE FUNCTION billing.lock_account(p_account uuid)
 RETURNS billing.accounts
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare a billing.accounts;
begin
  select * into a from billing.accounts where id = p_account for update;
  if not found then raise exception 'no such account' using errcode = 'P0002'; end if;
  return a;
end $function$;
