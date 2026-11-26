CREATE OR REPLACE FUNCTION public.my_plant_ids()
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select se.plant from billing.seats se join billing.accounts a on a.id = se.account
    join plants.plant_info p on p.id = se.plant
   where a.user_id = auth.uid() and se.closed_at is null and (select f.history_purged_at from billing.plant_facts f where f.plant = p.id) is null
     and not private.history_deleting(se.plant)                                -- 0277
     -- a share removed or a plant gone from the login: hidden; its history stays and shows again
     and billing.has_route(a.id, se.plant, false)
     -- not paying (ended, or over its places): its own history only, never a plant another
     -- account keeps, whose seat here never closes (it would see that payer's readings for good)
     and ((select st.state in ('trialing', 'active', 'past_due') and not st.must_choose
             from billing.account_status(a.id, now()) st)
          or not billing.kept_elsewhere(a.id, se.plant, now()))
$function$;
