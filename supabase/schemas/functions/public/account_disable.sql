CREATE OR REPLACE FUNCTION public.account_disable(p_account uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'vault', 'pg_temp'
AS $function$
declare sid uuid;
begin
  select refresh_secret_id into sid from private.sunsynk_accounts where id = p_account;
  update private.sunsynk_accounts
     set status = 'disabled', access_token = null, access_expires_at = null, refresh_secret_id = null
   where id = p_account;
  if sid is not null then delete from vault.secrets where id = sid; end if;
end $function$;
