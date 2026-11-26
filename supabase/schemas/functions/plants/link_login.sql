CREATE OR REPLACE FUNCTION plants.link_login(p_account uuid, p_brand text, p_username text, p_plants jsonb, p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text, p_id uuid DEFAULT NULL::uuid, p_access text DEFAULT NULL::text, p_expires bigint DEFAULT NULL::bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  st billing.status;
  l plants.logins;
  uid uuid := (select a.user_id from billing.accounts a where a.id = p_account);
  is_new boolean;
  seen jsonb;
begin
  -- the same login whatever the case of its email (the brand ignores it)
  select * into l from plants.logins x
   where x.account = p_account and x.brand = p_brand and lower(x.username) = lower(p_username)
   order by x.username = p_username desc, x.id limit 1;
  if l.id is not null then perform pg_advisory_xact_lock(1, hashtext(l.id::text)); end if;
  perform billing.lock_account(p_account);
  -- read again under the locks: a remove or another link may have finished while this waited
  select * into l from plants.logins x
   where x.account = p_account and x.brand = p_brand and lower(x.username) = lower(p_username)
   order by x.username = p_username desc, x.id limit 1;
  is_new := l.id is null;
  st := billing.account_status(p_account, p_at);
  if is_new then
    if st.state = 'ended' then
      raise exception 'no login can be added without a plan' using errcode = '22023';
    end if;
    if st.state in ('none', 'trialing') and exists (select 1 from plants.logins x where x.account = p_account) then
      raise exception 'one login during the free week' using errcode = '22023';
    end if;
    insert into plants.logins (id, account, user_id, brand, kind, username, status, linked_at,
                               access_token, access_expires_at, last_ok_at)
    values (coalesce(p_id, gen_random_uuid()), p_account, uid, p_brand, 'login', p_username, 'ok', p_at,
            p_access, p_expires, case when p_access is not null then p_at end)
    returning * into l;
  else
    -- before the update wipes status and last_error
    insert into plants.login_events (account_id, event, reason, last_ok_at, access_expires_at)
    values (l.id, 'relinked', l.status || coalesce(': ' || l.last_error, ''), l.last_ok_at, l.access_expires_at);
    update plants.logins x set status = 'ok', last_error = null,
           access_token = coalesce(p_access, x.access_token), access_expires_at = coalesce(p_expires, x.access_expires_at),
           last_ok_at = case when p_access is not null then p_at else x.last_ok_at end
     where x.id = l.id returning * into l;
  end if;
  seen := plants.list_seen(l.id, p_plants, p_at, 'relink');
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, case when is_new then 'link_login' else 'relink_login' end,
                            jsonb_build_object('state', st.state),
                            jsonb_build_object('login', l.id, 'plants', seen->'plants'));
  return l.id;
end $function$;
