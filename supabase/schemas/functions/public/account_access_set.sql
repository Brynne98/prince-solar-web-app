CREATE OR REPLACE FUNCTION public.account_access_set(p_account uuid, p_access text, p_expires bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
begin
  perform private.login_lock(array(select p_account union select private.login_copies(p_account)), 'ok');
  update plants.logins
     set access_token = p_access, access_expires_at = p_expires, last_ok_at = now(), last_error = null
   where id = p_account;
  update plants.logins
     set access_token = p_access, access_expires_at = p_expires, status = 'ok', last_error = null
   where id in (select private.login_copies(p_account));
end $function$;
