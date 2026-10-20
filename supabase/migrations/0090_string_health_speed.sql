-- ============================================================================
-- 0090 — string check under 2 s, advisor RLS and index items (SOLAR-139).
--
-- 1. api_string_health took 4.5-7.7 s against the 8 s signed-in limit. Its
--    per-day sums joined 15 days to every string row of all 31 day partitions:
--    the day bounds come from a CTE, so nothing was pruned, 270k rows spilled
--    to disk and 4M row-day pairs were tested. Each day is now its own lateral
--    index scan on (plant_id, ts), which prunes to that day's partition at run
--    time. Same output; the per-day part went from 1.25 s to 0.1 s (495944,
--    20 Oct 2026). Only the s CTE changed.
--
-- 2. plant_users_read, profiles_own and client_errors_insert called auth.uid()
--    once per row. (select auth.uid()) runs it once per query. Same rule.
--
-- 3. Indexes for the 4 foreign keys the advisor lists without one, so a delete
--    on the parent (auth.users, private.sunsynk_accounts) does not scan.
--
-- Left as they are on purpose: search_path on the 22 SQL helpers (local_ts,
-- today_tz, ...). A SET clause stops Postgres inlining a SQL function, and
-- these run per row inside api_overview and the rollups. No role but postgres
-- can create objects in public or private, so the path cannot be hijacked.
-- ============================================================================

create or replace function public.api_string_health(p_plant bigint default null)
returns jsonb
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  z as (select public.plant_tz((select id from pl)) as tz),
  t as (
    select public.day_start_epoch_tz(public.today_tz((select tz from z)), (select tz from z)) as t0,
           extract(epoch from now())::bigint as nw
  ),
  w as (select greatest((select nw from t) - (select t0 from t), 60) as len),
  days as (
    select g as k, public.day_start_epoch_tz(public.today_tz((select tz from z)) - g, (select tz from z)) as d0
      from generate_series(0, 14) g
  ),
  used as (
    select st.sn, st.no
      from public.strings st
     where st.plant_id = (select id from pl)
       and st.ts >= (select d0 from days where k = 14)
       and st.power_w >= 50
     group by st.sn, st.no
  ),
  s as (
    select d.k, x.sn, x.no, x.kwh
      from days d
      cross join lateral (
        select st.sn, st.no, sum(greatest(st.power_w, 0)) / 60000.0 as kwh
          from public.strings st
         where st.plant_id = (select id from pl)
           and st.ts >= d.d0 and st.ts < d.d0 + (select len from w)
         group by st.sn, st.no
      ) x
      join used u on u.sn = x.sn and u.no = x.no
  ),
  tot as (
    select k, sn, kwh,
           sum(kwh) over (partition by k, sn) as inv_kwh,
           sum(kwh) over (partition by k) as plant_kwh,
           no
      from s
  ),
  shares as (
    select k, sn, no, kwh, plant_kwh,
           case when inv_kwh > 0 then kwh / inv_kwh end as inv_share,
           case when plant_kwh > 0 then kwh / plant_kwh end as plant_share
      from tot
  ),
  usual as (
    select sn, no, avg(inv_share) as inv_share, avg(plant_share) as plant_share
      from shares
     where k between 1 and 14 and plant_kwh > 1
     group by sn, no
  ),
  hist as (
    select count(distinct k) as n from shares where k between 1 and 14 and plant_kwh > 1
  ),
  batt as (
    select r.sn, max(r.batt_soc) >= 98 as full
      from public.readings r
     where r.plant_id = (select id from pl) and r.ts >= (select t0 from t)
     group by r.sn
  ),
  last as (
    select st.sn, max(st.ts) as ts
      from public.strings st
     where st.plant_id = (select id from pl) and st.ts >= (select t0 from t)
     group by st.sn
  ),
  inv as (
    select u.sn,
           jsonb_agg(jsonb_build_object(
             'no', u.no,
             'todayKwh', round(coalesce(td.kwh, 0)::numeric, 2),
             'todayInvShare', round(td.inv_share::numeric, 4),
             'todayPlantShare', round(td.plant_share::numeric, 4),
             'usualInvShare', round(us.inv_share::numeric, 4),
             'usualPlantShare', round(us.plant_share::numeric, 4)) order by u.no) as strings
      from used u
      left join shares td on td.k = 0 and td.sn = u.sn and td.no = u.no
      left join usual us on us.sn = u.sn and us.no = u.no
     group by u.sn
  )
  select jsonb_build_object(
    'historyDays', (select n from hist),
    'todayKwh', round(coalesce((select max(plant_kwh) from shares where k = 0), 0)::numeric, 2),
    'inverters', coalesce((select jsonb_agg(jsonb_build_object(
        'sn', i.sn,
        'battFull', coalesce(b.full, false),
        'lastTs', l.ts,
        'strings', i.strings) order by i.sn)
      from inv i left join batt b on b.sn = i.sn left join last l on l.sn = i.sn), '[]'::jsonb))
$$;
revoke all on function public.api_string_health(bigint) from public, anon;
grant execute on function public.api_string_health(bigint) to authenticated, service_role;

alter policy plant_users_read on public.plant_users
  using (user_id = (select auth.uid()));
alter policy profiles_own on public.profiles
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
alter policy client_errors_insert on public.client_errors
  with check (user_id = (select auth.uid()));

create index if not exists inverters_account_id_idx on private.inverters (account_id);
create index if not exists client_errors_user_id_idx on public.client_errors (user_id);
create index if not exists plant_config_updated_by_idx on public.plant_config (updated_by);
create index if not exists plant_users_account_id_idx on public.plant_users (account_id);
