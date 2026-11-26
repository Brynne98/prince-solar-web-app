CREATE OR REPLACE FUNCTION private.refresh_store(p_account uuid, p_refresh text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'private', 'vault', 'pg_temp'
AS $function$
declare
  old_id uuid;
  new_id uuid;
begin
  -- Vault secret names are unique, so the old one must go before the new one is
  -- created under the same name. Same transaction: there is never a moment with
  -- no secret on file.
  select refresh_secret_id into old_id from plants.logins where id = p_account;
  if old_id is not null then
    update plants.logins set refresh_secret_id = null where id = p_account;
    delete from vault.secrets where id = old_id;
  end if;
  new_id := vault.create_secret(p_refresh, 'brand_refresh_' || p_account::text,
                                'brand refresh token for login ' || p_account::text);
  update plants.logins set refresh_secret_id = new_id where id = p_account;
end $function$;
