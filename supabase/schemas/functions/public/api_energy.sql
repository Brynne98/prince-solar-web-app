CREATE OR REPLACE FUNCTION public.api_energy(p_period text DEFAULT 'week'::text, p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  today as (select public.today_tz(public.plant_tz((select id from pl))) as d),
  period as (select case when p_period in ('week','month','year','lifetime') then p_period else 'week' end as p),
  -- week and month are built from day rows, so they follow the finished-row rule and now
  -- carry today as well; year and lifetime stay on the vendor's month buckets
  dayrows as (
    select 'day'::text as bucket, e.period, e.pv_kwh, e.load_kwh, e.imp_kwh, e.exp_kwh, e.chg_kwh, e.dischg_kwh
      from period, today,
           public._plant_day_energy((select id from pl),
             case period.p when 'month' then date_trunc('month', today.d)::date
                            else date_trunc('week', today.d)::date end,
             today.d) e
     where period.p in ('week','month')
  ),
  monthrows as (
    select e.bucket, e.period, e.pv_kwh, e.load_kwh, e.imp_kwh, e.exp_kwh, e.chg_kwh, e.dischg_kwh
      from public.plant_energy e, today, period
     where e.plant_id = (select id from pl)
       and period.p in ('year','lifetime')
       and case period.p
             when 'year' then e.bucket = 'month' and extract(year from e.period) = extract(year from today.d)
             else e.bucket = 'month' end
  ),
  rows as (select * from dayrows union all select * from monthrows)
  select jsonb_build_object('period', (select p from period),
    'rows', coalesce((select jsonb_agg(public._energy_row(r.bucket, r.period, r.pv_kwh, r.load_kwh, r.imp_kwh, r.exp_kwh, r.chg_kwh, r.dischg_kwh) order by r.period) from rows r), '[]'::jsonb))
$function$;
