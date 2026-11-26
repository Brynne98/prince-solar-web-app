CREATE OR REPLACE FUNCTION private.reports_due(p_now timestamp with time zone)
 RETURNS TABLE(user_id uuid, plant_id bigint, d date, period text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with loc as (
    select pu.user_id, pu.plant_id, timezone(public.plant_tz(pu.plant_id), p_now) as t,
           timezone(public.plant_tz(pu.plant_id), pu.linked_at)::date as linked_on
      from public.plant_users pu
  )
  select l.user_id, l.plant_id, l.t::date, p.period
    from loc l, lateral (values ('week', 3), ('month', 7), ('year', 30)) p(period, min_days)
   where extract(hour from l.t) >= 7
     and case p.period when 'week'  then extract(isodow from l.t) = 1
                       when 'month' then extract(day from l.t) = 1
                       else extract(day from l.t) = 1 and extract(month from l.t) = 1 end
     -- the days from linked_on to the day before the report: at least min_days
     and l.linked_on <= l.t::date - p.min_days
$function$;
