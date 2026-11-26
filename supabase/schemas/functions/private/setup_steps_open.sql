CREATE OR REPLACE FUNCTION private.setup_steps_open(p_plant bigint)
 RETURNS text[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select array_remove(array[
           case when not coalesce(c.tariff_import > 0, false) then 'rate' end,
           case when c.has_battery is distinct from false and not coalesce(c.battery_kwh > 0, false) then 'size' end,
           case when c.has_battery is distinct from false and not coalesce(c.battery_reserve_confirmed, false)
                 and coalesce(c.battery_reserve_pct, 20) = 20 then 'reserve' end,
           case when not coalesce(c.system_kwp > 0, false) then 'panels' end], null)
    from (select 1) one
    left join public.plant_config c on c.plant_id = p_plant
$function$;
