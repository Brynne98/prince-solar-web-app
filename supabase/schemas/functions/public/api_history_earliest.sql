CREATE OR REPLACE FUNCTION public.api_history_earliest(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select jsonb_build_object('earliest', (
    select to_char(min(period), 'YYYY-MM-DD') from public.plant_energy
     where plant_id = public.my_plant(p_plant)
       and bucket = 'day'
       and (coalesce(pv_kwh,0) > 0 or coalesce(load_kwh,0) > 0
            or coalesce(imp_kwh,0) > 0 or coalesce(exp_kwh,0) > 0
            or coalesce(chg_kwh,0) > 0 or coalesce(dischg_kwh,0) > 0)))
$function$;
