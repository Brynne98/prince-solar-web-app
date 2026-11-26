CREATE OR REPLACE FUNCTION private.login_copies(p_account uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
  select o.id
    from plants.logins a
    join plants.logins o
      on o.brand = a.brand and lower(o.username) = lower(a.username)
   where a.id = p_account and o.id <> p_account and o.status <> 'disabled'
$function$;
