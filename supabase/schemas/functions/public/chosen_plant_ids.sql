CREATE OR REPLACE FUNCTION public.chosen_plant_ids(p_user uuid)
 RETURNS bigint[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select array(select se.plant from billing.seats se join billing.accounts a on a.id = se.account
                where a.user_id = p_user and se.closed_at is null
                  and billing.has_route(a.id, se.plant, false) order by se.plant)
$function$;
