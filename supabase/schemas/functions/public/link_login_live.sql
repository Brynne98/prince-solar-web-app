CREATE OR REPLACE FUNCTION public.link_login_live(p_user uuid, p_username text, p_access text, p_expires bigint, p_refresh text, p_plants jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  acc uuid;
  login uuid;
  mine uuid[];
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  -- the login's lock, then the account, then the plants (R19); every copy of the username too
  mine := private.username_logins(p_user, p_username);
  perform private.login_lock(mine, 'ok', p_user,
    array(select lp.plant from plants.login_plants lp where lp.login = any (mine)
          union select (x->>'id')::bigint from jsonb_array_elements(plants.list_ids(plants.default_brand(), p_plants)) x));
  if not plants.link_allowed(p_user, plants.default_brand(), p_username) then
    raise exception 'one login' using errcode = '22023';
  end if;
  acc := billing.account_of(p_user);
  login := plants.link_login(acc, plants.default_brand(), p_username, coalesce(p_plants, '[]'::jsonb), now(), 'owner',
                             null, p_access, p_expires);
  -- a fresh sign-in replaces whatever the other copies of this username held
  update plants.logins
     set access_token = p_access, access_expires_at = p_expires, status = 'ok', last_error = null
   where id in (select private.login_copies(login));
  perform public.account_refresh_set(login, p_refresh);
  return login;
end
$function$;
