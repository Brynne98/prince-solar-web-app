-- ============================================================================
-- 0080 — which days have data, for the calendar pop-up. (SOLAR-72)
--
-- Every date bar now opens our own calendar, and days with nothing logged are
-- greyed out and can't be picked. A day counts when its daily total row holds any
-- solar or use, or, for the last week (whose rows the daily sync may not have
-- written yet), when it has any minute reading. Returns ["YYYY-MM-DD", ...] oldest
-- first, in the plant's own calendar.
--
-- Security definer like the other api_* readers (SOLAR-35): my_plant(p_plant)
-- raises unless auth.uid() is linked to the plant.
-- ============================================================================

create or replace function public.api_data_days(p_plant bigint default null)
returns jsonb
language sql
stable
security definer
set search_path to public, pg_temp
as $fn$
  with pl as (select public.my_plant(p_plant) as id),
  tz as (select public.plant_tz((select id from pl)) as tz),
  t as (select public.today_tz((select tz from tz)) as d),
  days as (
    select e.period as d
      from public.plant_energy e
     where e.plant_id = (select id from pl) and e.bucket = 'day'
       and (coalesce(e.pv_kwh, 0) > 0 or coalesce(e.load_kwh, 0) > 0)
    union
    select (t.d - g.i)
      from t, generate_series(0, 6) g(i)
     where exists (select 1 from public.agg_minute a
                    where a.plant_id = (select id from pl)
                      and a.ts >= public.day_start_epoch_tz(t.d - g.i, (select tz from tz))
                      and a.ts <  public.day_start_epoch_tz(t.d - g.i + 1, (select tz from tz)))
  )
  select coalesce(jsonb_agg(to_char(d, 'YYYY-MM-DD') order by d), '[]'::jsonb) from days
$fn$;

revoke all on function public.api_data_days(bigint) from public, anon;
grant execute on function public.api_data_days(bigint) to authenticated, service_role;
