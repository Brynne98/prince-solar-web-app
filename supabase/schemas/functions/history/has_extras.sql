CREATE OR REPLACE FUNCTION history.has_extras(p_plant bigint, p_day date)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with b as (select public.day_start_epoch_tz(p_day, plants.tz(p_plant)) lo,
                    public.day_start_epoch_tz(p_day + 1, plants.tz(p_plant)) hi),
  inv as (select i.sn from plants.inverter_info i where i.plant_id = p_plant)
  select exists (select 1 from inv)
     and not exists (
       select 1 from inv, b
        where (select count(*) from public.inverter_history h
                where h.plant_id = p_plant and h.sn = inv.sn and h.ts >= b.lo and h.ts < b.hi
                  and h.ac_c is not null and h.dc_c is not null) < 100
          and (select count(*) from public.inverter_history_5m h
                where h.plant_id = p_plant and h.sn = inv.sn and h.ts >= b.lo and h.ts < b.hi
                  and h.ac_max is not null and h.dc_max is not null) < 100)
$function$;
