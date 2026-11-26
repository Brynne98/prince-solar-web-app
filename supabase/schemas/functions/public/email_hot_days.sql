CREATE OR REPLACE FUNCTION public.email_hot_days(p_plant bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select count(distinct (timezone(public.plant_tz(p_plant), to_timestamp(h.ts)))::date)::int
    from public.readings h
   where h.plant_id = p_plant and h.ts >= extract(epoch from now())::bigint - 30 * 86400
     and h.batt_temp_c > 45 and h.batt_temp_c < 80
$function$;
