-- Silent inverter tests (SOLAR-555, 0202). A plant with two inverters; the master stops
-- reporting partway through today, so the newest minute holds the slave only. Needs the
-- local database at the latest migration. Runs inside one transaction, then rolls it back.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/sql/silent-inverter-tests.sql
-- Exit code decides: any wrong case raises.
\set QUIET on
begin;
create temp table fails (n serial, what text);
create function pg_temp.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is distinct from want then insert into pg_temp.fails (what) values (format('%s: got %s, want %s', label, got, want)); end if;
end $$;

-- Plant 9555001: master M555 silent for the last 12 minutes, slave S555 in every minute.
-- G555 is a ghost: known, but its last row is 3 days old (outside the 2-day window), so
-- it is not listed.
-- Yesterday at the same clock time: master 20.0, slave 15.0 kWh made.
create temp table fx as
  select '00000000-0000-0000-0000-000000000555'::uuid as u, 9555001::bigint as p,
         -- the newest minute: now, but at least 30 min into the local day
         greatest((extract(epoch from now())::bigint / 60) * 60,
                  public.day_start_epoch_tz(public.today_tz('Africa/Johannesburg'), 'Africa/Johannesburg') + 1800) as t;
grant select on fx to authenticated;

insert into auth.users (id, email) select u, 'silent@t.test' from fx;
-- on a plan: with none, a plant is read only in its free week (0204, SOLAR-552)
insert into private.billing (user_id, plan, period, billing_day, next_billing_date) select u, 'home', 'monthly', 1, current_date + 20 from fx;
insert into public.plant_config (plant_id) select p from fx;
-- the owner's pick (0197), as billing-tests.sql makes it: an unpicked link starts paused,
-- and readings for a paused plant are refused
select private.plant_pick_add(u, p, 'Silent') from fx \g /dev/null
insert into public.plant_users (plant_id, user_id, plant_name) select p, u, 'Silent' from fx;
insert into private.inverters (sn, plant_id) select s, p from fx, unnest(array['M555', 'S555', 'G555']) s;
insert into private.meta (sn, alias, plant_id) select s, s, p from fx, unnest(array['M555', 'S555', 'G555']) s;

-- today: master minutes t-20 .. t-12, slave t-20 .. t; day totals rise each minute
insert into public.readings (plant_id, sn, ts, carried, device_time, status, pv_w, load_w, grid_w, batt_w, batt_soc,
                             pv_today_kwh, load_today_kwh, grid_import_today_kwh, grid_volt_v)
select p, sn, t - m * 60, false,
       to_char(to_timestamp(t - m * 60) at time zone 'Africa/Johannesburg', 'YYYY-MM-DD HH24:MI:SS'),
       '1', w, 500, 0, 0, 80,
       base - (m - upto) * 0.1, 10 - (m - upto) * 0.1, 0, 230
  from fx, (values ('M555', 9000, 24.7, 12), ('S555', 3000, 19.2, 0)) v(sn, w, base, upto),
       generate_series(v.upto, 20) m;
-- yesterday: one row each a minute before the same clock time; the ghost's only row is
-- 3 days back
insert into public.readings (plant_id, sn, ts, carried, device_time, status, pv_w, pv_today_kwh, load_today_kwh, grid_import_today_kwh)
select p, sn, t - d * 86400 - 60, false,
       to_char(to_timestamp(t - d * 86400 - 60) at time zone 'Africa/Johannesburg', 'YYYY-MM-DD HH24:MI:SS'),
       '1', 1000, kwh, 5, 0
  from fx, (values ('M555', 20.0, 1), ('S555', 15.0, 1), ('G555', 7.0, 3)) v(sn, kwh, d);

-- Plant 9555002: Y555 silent since yesterday 23:00 local (30.0 kWh made yesterday),
-- L555 in every minute today (12.0 kWh made so far).
create temp table fy as
  select '00000000-0000-0000-0000-000000000556'::uuid as u, 9555002::bigint as p, t,
         public.day_start_epoch_tz(public.today_tz('Africa/Johannesburg'), 'Africa/Johannesburg') - 3600 as y
    from fx;
insert into auth.users (id, email) select u, 'silent2@t.test' from fy;
-- on a plan: with none, a plant is read only in its free week (0204, SOLAR-552)
insert into private.billing (user_id, plan, period, billing_day, next_billing_date) select u, 'home', 'monthly', 1, current_date + 20 from fy;
insert into public.plant_config (plant_id) select p from fy;
select private.plant_pick_add(u, p, 'Silent 2') from fy \g /dev/null
insert into public.plant_users (plant_id, user_id, plant_name) select p, u, 'Silent 2' from fy;
insert into private.inverters (sn, plant_id) select s, p from fy, unnest(array['Y555', 'L555']) s;
insert into private.meta (sn, alias, plant_id) select s, s, p from fy, unnest(array['Y555', 'L555']) s;
insert into public.readings (plant_id, sn, ts, carried, device_time, status, pv_w, load_w, batt_w, batt_soc,
                             pv_today_kwh, load_today_kwh, batt_chg_today_kwh, grid_import_today_kwh)
select p, sn, ts, false, to_char(to_timestamp(ts) at time zone 'Africa/Johannesburg', 'YYYY-MM-DD HH24:MI:SS'),
       '1', 2000, 500, 0, 80, kwh, 20, 5, 1
  from fy, lateral (values ('Y555', y - 1800, 29.5), ('Y555', y, 30.0),
                           ('L555', t - 1200, 11.5), ('L555', t, 12.0)) v(sn, ts, kwh);

do $$
declare
  p bigint := (select p from fx); t bigint := (select t from fx);
  ov jsonb; ps jsonb; tc jsonb; m jsonb; s jsonb;
begin
  ov := public.api_overview(p);
  perform pg_temp.eq('overview: todayPv is both inverters'' last day totals', (ov->'totals'->>'todayPv')::numeric, 43.90);
  perform pg_temp.eq('overview: 2 inverters listed', jsonb_array_length(ov->'inverters'), 2);
  m := (select i from jsonb_array_elements(ov->'inverters') i where i->>'sn' = 'M555');
  s := (select i from jsonb_array_elements(ov->'inverters') i where i->>'sn' = 'S555');
  perform pg_temp.eq('overview: master readAt is its last row, 12 min old', (m->>'readAt')::bigint, t - 720);
  perform pg_temp.eq('overview: slave readAt is the newest minute', (s->>'readAt')::bigint, t);
  perform pg_temp.eq('overview: master keeps its own load today', (m->'load'->>'today')::numeric, 10.0);
  perform pg_temp.eq('overview: live solar is the slave alone', (ov->'totals'->>'pv')::numeric, 3000::numeric);
  perform pg_temp.eq('overview: ghost not listed', (select count(*) from jsonb_array_elements(ov->'inverters') i where i->>'sn' = 'G555')::int, 0);

  perform set_config('request.jwt.claims', json_build_object('sub', (select u from fx), 'role', 'authenticated')::text, true);
  ps := (select e from jsonb_array_elements(public.api_plant_states()) e where (e->>'id')::bigint = p);
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.eq('plant states: 2 inverters', (ps->>'inverters')::int, 2::int);
  perform pg_temp.eq('plant states: 1 online', (ps->>'online')::int, 1);
  perform pg_temp.eq('plant states: lastTs is the newest minute', (ps->>'lastTs')::bigint, t);

  tc := public.api_trends_compare(p);
  perform pg_temp.eq('trend compare: yesterday same time counts both inverters', (tc->'today'->'prev'->>'pv')::numeric, 35.0);

  -- silent since yesterday 23:00: listed and offline, adds nothing to today
  p := (select fy.p from fy);
  ov := public.api_overview(p);
  m := (select i from jsonb_array_elements(ov->'inverters') i where i->>'sn' = 'Y555');
  perform pg_temp.eq('since yesterday: 2 inverters listed', jsonb_array_length(ov->'inverters'), 2);
  perform pg_temp.eq('since yesterday: readAt is yesterday 23:00', (m->>'readAt')::bigint, (select y from fy));
  perform pg_temp.eq('since yesterday: reads offline (over 15 min old)', (m->>'readAt')::bigint < t - 900, true);
  perform pg_temp.eq('since yesterday: Made today excludes its yesterday total', (ov->'totals'->>'todayPv')::numeric, 12.00);
  perform pg_temp.eq('since yesterday: its card made today is 0', (m->'pv'->>'today')::numeric, 0::numeric);
  perform pg_temp.eq('since yesterday: its card used today is 0', (m->'load'->>'today')::numeric, 0::numeric);
  perform pg_temp.eq('since yesterday: its card charged today is 0', (m->'battery'->>'todayCharged')::numeric, 0::numeric);
  perform pg_temp.eq('since yesterday: live solar is the live inverter alone', (ov->'totals'->>'pv')::numeric, 2000::numeric);
  perform set_config('request.jwt.claims', json_build_object('sub', (select u from fy), 'role', 'authenticated')::text, true);
  ps := (select e from jsonb_array_elements(public.api_plant_states()) e where (e->>'id')::bigint = p);
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.eq('since yesterday: plant states 2 inverters', (ps->>'inverters')::int, 2::int);
  perform pg_temp.eq('since yesterday: plant states 1 online', (ps->>'online')::int, 1);
end $$;

-- the window lookup for an inverter silent since yesterday, timed: under 5 ms
do $$
declare t0 timestamptz := clock_timestamp(); x bigint; ms numeric;
begin
  select rd.ts into x from public.readings rd
   where rd.sn = 'Y555' and rd.plant_id = 9555002
     and rd.ts >= extract(epoch from now())::bigint - 2 * 86400 and rd.ts <= (select t from fx)
   order by rd.ts desc limit 1;
  ms := extract(epoch from clock_timestamp() - t0) * 1000;
  perform pg_temp.eq('window lookup found yesterday 23:00', x, (select y from fy));
  if ms >= 5 then insert into pg_temp.fails (what) values (format('window lookup took %s ms, want under 5', round(ms, 2))); end if;
end $$;

\set QUIET off
-- the silent inverter's lookup over the 2-day window, as api_overview runs it: one
-- probe on the sn_ts index
explain (analyze, costs off, timing off, summary on)
select rd.ts from public.readings rd, fy
 where rd.sn = 'Y555' and rd.plant_id = fy.p
   and rd.ts >= extract(epoch from now())::bigint - 2 * 86400 and rd.ts <= fy.t
 order by rd.ts desc limit 1;

do $$ begin
  if exists (select 1 from pg_temp.fails) then
    raise exception E'silent inverter tests failed:\n%', (select string_agg(what, E'\n' order by n) from pg_temp.fails);
  end if;
end $$;
select 'PASS' as silent_inverter_tests;
rollback;
