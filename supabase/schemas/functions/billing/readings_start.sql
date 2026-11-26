CREATE OR REPLACE FUNCTION billing.readings_start(p_account uuid, p_plants bigint[], p_at timestamp with time zone)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into private.plant_alert_state (plant_id, started_at)
  select c.plant_id, extract(epoch from p_at)::bigint from plants.settings c
   where c.plant_id = any (p_plants)
     and not exists (select 1 from billing.seats s where s.plant = c.plant_id and s.account <> p_account
                        and s.closed_at is null and billing.reads_plant(s.account, c.plant_id, p_at))
  on conflict (plant_id) do update
    set started_at = greatest(coalesce(private.plant_alert_state.started_at, 0), excluded.started_at)
$function$;
