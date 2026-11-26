CREATE OR REPLACE FUNCTION public.link_login_live(p_user uuid, p_username text, p_access text, p_expires bigint, p_refresh text, p_plants jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  acc uuid;
  mine uuid[];
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  mine := private.username_logins(p_user, p_username);
  perform private.login_lock(mine, 'active', p_user,
    array(select (e->>'id')::bigint from jsonb_array_elements(coalesce(p_plants, '[]'::jsonb)) e where e->>'id' is not null
          union
          select lp.plant from billing.login_plants lp join billing.logins bl on bl.id = lp.login
           join billing.accounts ba on ba.id = bl.account
           where ba.user_id = p_user and bl.id = any (mine)));
  acc := public.account_upsert(p_user, p_username, p_access, p_expires);
  perform public.account_refresh_set(acc, p_refresh);
  perform public.billing_links('link_login', jsonb_build_object('user', p_user, 'login', acc, 'username', p_username,
                                                                 'plants', coalesce(p_plants, '[]'::jsonb)));
  return acc;
end $function$;
