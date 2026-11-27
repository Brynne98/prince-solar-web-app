CREATE OR REPLACE FUNCTION history.has_extras(p_plant bigint, p_day date)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with b as (select public.day_start_epoch_tz(p_day, plants.tz(p_plant)) lo,
                    public.day_start_epoch_tz(p_day + 1, plants.tz(p_plant)) hi)
  select (select count(*) from public.inverter_history h, b
           where h.plant_id = p_plant and h.ts >= b.lo and h.ts < b.hi and h.ac_c is not null and h.dc_c is not null) >= 100
      or (select count(*) from public.inverter_history_5m h, b
           where h.plant_id = p_plant and h.ts >= b.lo and h.ts < b.hi and h.ac_max is not null and h.dc_max is not null) >= 100
$function$;
