CREATE OR REPLACE FUNCTION public.api_link_remove(p_account uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  acc uuid := billing.account_of(auth.uid(), false);
  shared bigint[];
  p bigint;
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and user_id = auth.uid())
     and not exists (select 1 from private.sunsynk_accounts a where a.id = p_account and a.kind = 'share'
                       and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid())) then
    raise exception 'not your account' using errcode = '42501';
  end if;
  shared := array(select x.plant_id from public.plant_users x where x.account_id = p_account and x.user_id = auth.uid());
  if exists (select 1 from private.sunsynk_accounts where id = p_account and kind = 'share') then
    perform private.share_release(p_account, auth.uid());
    if acc is not null and cardinality(shared) > 0 then perform billing.unclaim(acc, shared); end if;
  else
    perform pg_advisory_xact_lock_shared(3, 0);
    perform pg_advisory_xact_lock(1, hashtext(p_account::text));
    for p in select x.plant_id from public.plant_users x
              where x.account_id = p_account and x.user_id = auth.uid() order by x.plant_id loop
      perform pg_advisory_xact_lock(p);
    end loop;
    perform 1 from public.plant_users x
     where x.account_id = p_account and x.user_id = auth.uid() order by x.plant_id for update;
    if acc is not null and exists (select 1 from billing.logins where id = p_account and account = acc) then
      perform billing.lock_account(acc);
      perform billing.lock_plants(array(select plant from billing.login_plants where login = p_account));
    end if;
    perform public.api_link_disconnect(p_account);
    if acc is not null and exists (select 1 from billing.logins where id = p_account and account = acc) then
      perform billing.remove_login(acc, p_account);
    end if;
  end if;
  return jsonb_build_object('result', 'removed');
end $function$;
