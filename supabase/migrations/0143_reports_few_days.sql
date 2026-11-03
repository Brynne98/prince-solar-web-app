-- SOLAR-305, revised 2026-11-03: a plant added partway through a period still gets that
-- period's report once it has been here a few days (3 for a week, 7 for a month, 30 for
-- a year). notify counts only the days since it was added and says so in the report.
-- Was (0142): only plants linked by the period's first day.
create or replace function private.reports_due(p_now timestamptz)
returns table (user_id uuid, plant_id bigint, d date, period text)
language sql stable set search_path = public, private, pg_temp as $$
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
$$;
revoke all on function private.reports_due(timestamptz) from public, anon, authenticated;
