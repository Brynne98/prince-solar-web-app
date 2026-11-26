CREATE OR REPLACE FUNCTION public.account_refresh_set(p_account uuid, p_refresh text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'vault', 'pg_temp'
AS $function$
declare c uuid;
begin
  perform private.login_lock(array(select p_account union select private.login_copies(p_account)), null);
  perform private.refresh_store(p_account, p_refresh);
  for c in select private.login_copies(p_account) loop
    perform private.refresh_store(c, p_refresh);
  end loop;
end $function$;
