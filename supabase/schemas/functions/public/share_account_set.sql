CREATE OR REPLACE FUNCTION public.share_account_set(p_user uuid, p_username text, p_access text, p_expires bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare acc uuid;
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  select id into acc from plants.logins where kind = 'share' and brand = plants.default_brand();
  if acc is null then
    insert into plants.logins (user_id, account, brand, kind, username, status, access_token, access_expires_at, last_ok_at)
    values (p_user, null, plants.default_brand(), 'share', p_username, 'ok', p_access, p_expires, now())
    returning id into acc;
  else
    perform pg_advisory_xact_lock(1, hashtext(acc::text));
    update plants.logins set username = p_username, access_token = p_access, access_expires_at = p_expires,
                             status = 'ok', last_error = null, last_ok_at = now()
     where id = acc;
  end if;
  return acc;
end
$function$;
