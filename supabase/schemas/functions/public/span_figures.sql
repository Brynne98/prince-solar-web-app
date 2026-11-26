CREATE OR REPLACE FUNCTION public.span_figures(p_plant bigint, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object(
           'made_kwh', coalesce(sum(e.pv_kwh), 0), 'home_kwh', coalesce(sum(e.load_kwh), 0),
           'import_kwh', coalesce(sum(e.imp_kwh), 0),
           'independence_pct', public.independence_pct(coalesce(sum(e.load_kwh), 0), coalesce(sum(e.imp_kwh), 0)))
    from public._plant_day_energy(p_plant, p_from, p_to) e
   -- a day of zeros is the brand's filler for a day with no readings (notify hasData)
   where coalesce(e.load_kwh, 0) > 0 or coalesce(e.pv_kwh, 0) > 0
$function$;
