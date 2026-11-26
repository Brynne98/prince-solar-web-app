CREATE OR REPLACE FUNCTION public.account_refresh_get(p_account uuid)
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'private', 'vault', 'pg_temp'
AS $function$
  select ds.decrypted_secret
    from plants.logins a
    join vault.decrypted_secrets ds on ds.id = a.refresh_secret_id
   where a.id = p_account
$function$;
