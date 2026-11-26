CREATE OR REPLACE FUNCTION public.api_link_remove(p_account uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  uid uuid := auth.uid();
  acc uuid := billing.account_of(auth.uid(), false);
  l plants.logins;
  shared bigint[];
begin
  select * into l from plants.logins where id = p_account;
  if l.id is null or not (l.user_id = uid or (l.kind = 'share' and acc is not null
        and exists (select 1 from plants.claims c where c.account = acc))) then
    raise exception 'not your account' using errcode = '42501';
  end if;
  if l.kind = 'share' then
    -- the share login is not the owner's to remove: their claims on it go
    shared := array(select c.plant from plants.claims c where c.account = acc order by c.plant);
    delete from public.email_queue e where e.user_id = uid and e.plant_id = any (shared) and e.kind not like 'sunsynk_%';
    if cardinality(shared) > 0 then perform plants.unclaim(acc, shared); end if;
  else
    delete from public.email_queue e
     where e.user_id = uid
       and (e.plant_id in (select lp.plant from plants.login_plants lp where lp.login = p_account) and e.kind not like 'sunsynk_%'
            or e.key like 'needs_relink:' || p_account || ':%');
    update private.inverters set account_id = null where account_id = p_account;
    perform plants.remove_login(acc, p_account);
  end if;
  return jsonb_build_object('result', 'removed');
end
$function$;
