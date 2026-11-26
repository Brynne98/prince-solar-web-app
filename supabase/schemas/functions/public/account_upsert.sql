CREATE OR REPLACE FUNCTION public.account_upsert(p_user uuid, p_username text, p_access text, p_expires bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
declare acc uuid;
begin
  -- plant_users_upsert's order (0170), so two links at once queue here and the second sees the first's login
  perform pg_advisory_xact_lock_shared(3, 0);
  perform private.login_lock(private.username_logins(p_user, p_username), 'active', p_user);
  -- read under the locks: a delete or another link may have finished while this waited
  if not public.link_login_allowed(p_user, p_username) then
    raise exception 'one login' using errcode = '22023';
  end if;
  -- the same login whatever the case of its email (SunSynk ignores it): the row already
  -- stored is updated in place; a new one only when there is none
  select id into acc from private.sunsynk_accounts
   where user_id = p_user and kind = 'login' and lower(sunsynk_username) = lower(p_username)
   order by sunsynk_username = p_username desc, id limit 1;
  -- Before the update below wipes status and last_error. A first link has no row.
  insert into private.sunsynk_login_events (account_id, event, reason, last_ok_at, access_expires_at)
  select id, 'relinked', status || coalesce(': ' || last_error, ''), last_ok_at, access_expires_at
    from private.sunsynk_accounts where id = acc;
  if acc is null then
    insert into private.sunsynk_accounts (user_id, sunsynk_username, access_token, access_expires_at, status, last_ok_at, last_error)
    values (p_user, p_username, p_access, p_expires, 'active', now(), null)
    returning id into acc;
  else
    update private.sunsynk_accounts
       set access_token = p_access, access_expires_at = p_expires, status = 'active', last_ok_at = now(), last_error = null
     where id = acc;
  end if;
  -- A fresh sign-in replaces whatever the other copies held. The refresh token
  -- follows in account_refresh_set, which link-sunsynk calls next.
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires, status = 'active', last_error = null
   where id in (select private.login_copies(acc));
  return acc;
end $function$;
