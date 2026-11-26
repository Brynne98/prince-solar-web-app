CREATE OR REPLACE FUNCTION private.login_copies(p_account uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  select o.id
    from private.sunsynk_accounts a
    join private.sunsynk_accounts o
      on o.provider = a.provider and lower(o.sunsynk_username) = lower(a.sunsynk_username)
   where a.id = p_account and o.id <> p_account and o.status <> 'disabled'
$function$;
