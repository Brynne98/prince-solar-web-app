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
-- G555 is a ghost: known, but no row today (dead since yesterday), so it is not listed.
-- Yesterday at the same clock time: master 20.0, slave 15.0 kWh made.
create temp table fx as
  select '00000000-0000-0000-0000-000000000555'::uuid as u, 9555001::bigint as p,
         -- the newest minute: now, but at least 30 min into the local day
         greatest((extract(epoch from now())::bigint / 60) * 60,
                  public.day_start_epoch_tz(public.today_tz('Africa/Johannesburg'), 'Africa/Johannesburg') + 1800) as t;
grant select on fx to authenticated;

insert into auth.users (id, email) select u, 'silent@t.test' from fx;
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
-- yesterday: one row each a minute before the same clock time; the ghost's only row
insert into public.readings (plant_id, sn, ts, carried, device_time, status, pv_w, pv_today_kwh, load_today_kwh, grid_import_today_kwh)
select p, sn, t - 86400 - 60, false,
       to_char(to_timestamp(t - 86400 - 60) at time zone 'Africa/Johannesburg', 'YYYY-MM-DD HH24:MI:SS'),
       '1', 1000, kwh, 5, 0
  from fx, (values ('M555', 20.0), ('S555', 15.0), ('G555', 7.0)) v(sn, kwh);

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
end $$;

\set QUIET off
-- the silent inverter's lookup, as api_overview runs it: one probe on the sn_ts index
explain (analyze, costs off, timing off, summary off)
select rd.ts from public.readings rd, fx
 where rd.sn = 'M555' and rd.plant_id = fx.p
   and rd.ts >= public.day_start_epoch_tz(public.today_tz('Africa/Johannesburg'), 'Africa/Johannesburg') and rd.ts <= fx.t
 order by rd.ts desc limit 1;

do $$ begin
  if exists (select 1 from pg_temp.fails) then
    raise exception E'silent inverter tests failed:\n%', (select string_agg(what, E'\n' order by n) from pg_temp.fails);
  end if;
end $$;
select 'PASS' as silent_inverter_tests;
rollback;
