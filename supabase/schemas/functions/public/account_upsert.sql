CREATE OR REPLACE FUNCTION public.account_upsert(p_user uuid, p_username text, p_access text, p_expires bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
begin
  -- the link without a refresh token yet (the bootstrap login): link_login_live's path
  if not plants.link_allowed(p_user, plants.default_brand(), p_username) then
    raise exception 'one login' using errcode = '22023';
  end if;
  return plants.link_login(billing.account_of(p_user), plants.default_brand(), p_username, '[]'::jsonb, now(), 'owner',
                           null, p_access, p_expires);
end
$function$;
