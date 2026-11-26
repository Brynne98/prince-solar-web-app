CREATE OR REPLACE FUNCTION public.email_plant_inverters(p_plant bigint)
 RETURNS TABLE(sn text, last_dev bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select i.sn, s.last_dev
    from plants.inverter_info i
    left join private.inverter_alert_state s on s.plant_id = i.plant_id and s.sn = i.sn
   where i.plant_id = p_plant
   order by i.sn
$function$;
