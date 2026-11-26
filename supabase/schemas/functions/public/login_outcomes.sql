CREATE OR REPLACE FUNCTION public.login_outcomes(p_outcomes jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update plants.logins a set last_try_at = now(), last_try = o.outcome
    from jsonb_to_recordset(coalesce(p_outcomes, '[]'::jsonb)) as o(account uuid, outcome text)
   where a.id = o.account and o.outcome in ('ok', 'vendor', 'ours')
$function$;
