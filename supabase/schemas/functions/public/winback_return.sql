CREATE OR REPLACE FUNCTION public.winback_return(p_reference text)
 RETURNS TABLE(user_id uuid, email_id bigint, days integer, at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select (w->>'user')::uuid, (w->>'email_id')::bigint, (w->>'days')::int, (w->>'at')::timestamptz
    from (select billing.winback_return(p_reference) w) x
   where w is not null
$function$;
