CREATE OR REPLACE FUNCTION public.api_trends_daily(p_days integer DEFAULT 30, p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  d as (select least(greatest(coalesce(p_days, 30), 1), 120) as n),
  t as (select public.today_tz((select tz from pz)) as today),
  -- a window of calendar days, not "the last N rows that exist": the chart says last N days
  top as (
    select * from public._plant_day_energy((select id from pl),
                                           ((select today from t) - ((select n from d) - 1))::date,
                                           (select today from t))
  )
  select jsonb_build_object('days', (select n from d),
    'rows', coalesce((select jsonb_agg(
               public._energy_row('day', x.period, x.pv_kwh, x.load_kwh, x.imp_kwh, x.exp_kwh, x.chg_kwh, x.dischg_kwh)
               order by x.period)
        from top x), '[]'::jsonb))
$function$;
