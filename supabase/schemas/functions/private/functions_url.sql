CREATE OR REPLACE FUNCTION private.functions_url()
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare u text;
begin
  select decrypted_secret into u from vault.decrypted_secrets where name = 'functions_url';
  if coalesce(u, '') = '' then
    raise exception 'Vault secret functions_url is not set: no functions to call' using errcode = '55000';
  end if;
  return rtrim(u, '/');
end $function$;
