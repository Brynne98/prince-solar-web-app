CREATE OR REPLACE FUNCTION private.mail_blocked(p_email text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from private.mail_blocked b where b.email = lower(btrim(p_email)))
$function$;
