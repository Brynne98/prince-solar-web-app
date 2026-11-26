CREATE OR REPLACE FUNCTION public.plants_seen_before(p_user uuid, p_plants bigint[])
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select count(*)::int
    from plants.plants p
   where p.id = any (coalesce(p_plants, '{}'))
     and (select f.trial_used_at from billing.plant_facts f where f.plant = p.id) < (select u.created_at from auth.users u where u.id = p_user)
     and not exists (select 1 from billing.seats se join billing.accounts a on a.id = se.account
                      where se.plant = p.id and se.closed_at is null and a.user_id <> p_user)
$function$;
