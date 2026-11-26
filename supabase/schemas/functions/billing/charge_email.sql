CREATE OR REPLACE FUNCTION billing.charge_email(p_auth_email text, p_account uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select coalesce(p_auth_email, (select u.email from billing.accounts a join auth.users u on u.id = a.user_id
                                   where a.id = p_account))
$function$;
