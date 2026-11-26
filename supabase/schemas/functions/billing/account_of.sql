CREATE OR REPLACE FUNCTION billing.account_of(p_user uuid, p_create boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare acc uuid; mk text;
begin
  if p_user is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select id into acc from billing.accounts where user_id = p_user;
  if acc is null and p_create then
    mk := (select min(code) from billing.markets having count(*) = 1);
    if mk is null then raise exception 'which market?' using errcode = '22023'; end if;
    insert into billing.accounts (user_id, market) values (p_user, mk) on conflict (user_id) do nothing;
    select id into acc from billing.accounts where user_id = p_user;
  end if;
  return acc;
end $function$;
