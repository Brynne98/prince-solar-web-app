-- SOLAR-416 (0164): disconnect and grid-off notices carry when it happened.
--   psql "$DB_URL" -f scripts/sql/verify-0164.sql      (local database only; rolled back)
-- Exit code decides: any wrong case raises.
\set QUIET on
\set ON_ERROR_STOP on
\o /dev/null
begin;

create function pg_temp.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is distinct from want then raise exception 'FAIL %: got %, want %', label, got, want; end if;
  raise notice 'PASS  %', label;
end $$;
-- The 8 Nov shape, an hour ago: last reading T0, gap to T0+62 min, grid off 58 min in.
create function pg_temp.t(s int) returns bigint language sql as
  $$ select (extract(epoch from now())::bigint / 60) * 60 - 7200 + s $$;
create function pg_temp.hist(p bigint, sn text, s int, hz real) returns void language sql as
  $$ insert into public.inverter_history (plant_id, sn, ts, grid_fac_hz) values (p, p || sn, pg_temp.t(s), hz) $$;
create function pg_temp.off(p bigint, k int) returns void language sql as
  $$ select private.email_plant_apply(p, pg_temp.t(3720 + k * 60), '{"present": false, "has_batt": false}') $$;
create function pg_temp.on_(p bigint, k int) returns void language sql as
  $$ select private.email_plant_apply(p, pg_temp.t(3720 + k * 60), '{"present": true, "has_batt": false}') $$;

insert into auth.users (id, email)
  select ('00000000-0000-0000-0000-00000000' || p)::uuid, p || '@t.test' from unnest(array[9101, 9102, 9103, 9104]) p;
insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, last_ok_at)
  select ('00000000-0000-0000-0000-0000000a' || p)::uuid, ('00000000-0000-0000-0000-00000000' || p)::uuid, 'w' || p, 'active',
         to_timestamp(pg_temp.t(0))
    from unnest(array[9101, 9102, 9103, 9104]) p;
insert into public.plant_users (plant_id, user_id, account_id)
  select p, ('00000000-0000-0000-0000-00000000' || p)::uuid, ('00000000-0000-0000-0000-0000000a' || p)::uuid
    from unnest(array[9101, 9102, 9103, 9104]) p;
insert into public.plant_config (plant_id, has_battery) select p, false from unnest(array[9101, 9102, 9103, 9104]) p;
-- every plant: grid on before the gap, then a 62-minute gap
insert into private.plant_alert_state (plant_id, grid_on, grid_since, grid_run_on, grid_run_n, grid_run_start, stepped_ts)
  select p, true, pg_temp.t(-3600), true, 60, pg_temp.t(-3600), pg_temp.t(0) from unnest(array[9101, 9102, 9103, 9104]) p;
insert into private.gaps (plant_id, from_ts, to_ts) select p, pg_temp.t(0) + p - 9100, pg_temp.t(3720) from unnest(array[9101, 9102, 9103, 9104]) p;

-- ---- Login --------------------------------------------------------------------------------
update private.sunsynk_accounts set status = 'needs_relink' where sunsynk_username = 'w9101';
select pg_temp.eq('login: Reconnect needed says the last good poll, not now',
  (select (data->>'since')::bigint from public.email_queue where plant_id = 9101 and kind = 'needs_relink'), pg_temp.t(0));
update private.sunsynk_accounts set last_ok_at = null where sunsynk_username = 'w9102';
update private.sunsynk_accounts set status = 'needs_relink' where sunsynk_username = 'w9102';
select pg_temp.eq('login: no good poll on record says now',
  (select (data->>'since')::bigint from public.email_queue where plant_id = 9102 and kind = 'needs_relink'),
  extract(epoch from now())::bigint);
update private.sunsynk_accounts set status = 'active' where sunsynk_username = 'w9101';
select pg_temp.eq('login: Reconnected counts from the last good poll',
  (select (data->>'since')::bigint from public.email_queue where plant_id = 9101 and kind = 'relinked'), pg_temp.t(0));

-- ---- Grid, refill landed (9101): master on to 3047 s, off from 3111 s; slave every 5 min ---
select pg_temp.hist(9101, 'M', s, 49.9) from generate_series(60, 3047, 60) s;
select pg_temp.hist(9101, 'M', s, 0) from generate_series(3111, 3711, 60) s;
select pg_temp.hist(9101, 'S', s, 50.0) from generate_series(300, 3000, 300) s;
select pg_temp.hist(9101, 'S', 3300, 0);
select pg_temp.off(9101, k) from generate_series(0, 2) k;
select pg_temp.eq('grid: off inside a gap takes its start from the refilled history',
  (select data from public.email_queue where plant_id = 9101 and kind = 'grid_down') - 'chargePct',
  jsonb_build_object('since', pg_temp.t(3111)));
select pg_temp.eq('grid: the bell says the refilled time',
  (select private.alert_text('grid_down', data, now(), 'Africa/Johannesburg')->>'body' from public.email_queue where plant_id = 9101 and kind = 'grid_down'),
  'Off since ' || to_char(to_timestamp(pg_temp.t(3111)) at time zone 'Africa/Johannesburg', 'HH24:MI') || '.');
select pg_temp.on_(9101, k) from generate_series(3, 7) k;
select pg_temp.eq('grid: Grid back counts from the refilled start',
  (select (data->>'since')::bigint from public.email_queue where plant_id = 9101 and kind = 'grid_back'), pg_temp.t(3111));

-- ---- Grid, no refill yet (9102): a range from the gap's start --------------------------------
select pg_temp.off(9102, k) from generate_series(0, 2) k;
select pg_temp.eq('grid: no refill yet gives the gap as a range',
  (select data from public.email_queue where plant_id = 9102 and kind = 'grid_down') - 'chargePct',
  jsonb_build_object('since', pg_temp.t(3720), 'from', pg_temp.t(0) + 2));
select pg_temp.eq('grid: the bell says between',
  (select private.alert_text('grid_down', data, now(), 'Africa/Johannesburg')->>'body' from public.email_queue where plant_id = 9102 and kind = 'grid_down'),
  'Went off between ' || to_char(to_timestamp(pg_temp.t(0) + 2) at time zone 'Africa/Johannesburg', 'HH24:MI')
  || ' and ' || to_char(to_timestamp(pg_temp.t(3720)) at time zone 'Africa/Johannesburg', 'HH24:MI') || '.');

-- ---- Grid, refill on to 30 min in, then nothing (9103): range from the last on sample --------
select pg_temp.hist(9103, 'M', s, 50.0) from generate_series(60, 1800, 60) s;
select pg_temp.off(9103, k) from generate_series(0, 2) k;
select pg_temp.eq('grid: history that stops while on gives a range from the last on sample',
  (select data->>'from' from public.email_queue where plant_id = 9103 and kind = 'grid_down'), pg_temp.t(1800)::text);

-- ---- Grid, first minute after the gap had no voltage (9104): run starts a minute later -------
update private.gaps set to_ts = pg_temp.t(3660) where plant_id = 9104;
select pg_temp.hist(9104, 'M', s, 49.9) from generate_series(60, 3047, 60) s;
select pg_temp.hist(9104, 'M', s, 0) from generate_series(3111, 3711, 60) s;
select pg_temp.off(9104, k) from generate_series(0, 2) k;
select pg_temp.eq('grid: a gap that ended a minute before the off run still refines the start',
  (select (data->>'since')::bigint from public.email_queue where plant_id = 9104 and kind = 'grid_down'), pg_temp.t(3111));

-- ---- Grid, no gap: unchanged ----------------------------------------------------------------
delete from private.gaps where plant_id = 9103;
delete from public.email_queue where plant_id = 9103;
update private.plant_alert_state set grid_on = true, grid_run_on = true, grid_run_n = 60, grid_off_key = null, stepped_ts = pg_temp.t(3600)
 where plant_id = 9103;
select pg_temp.off(9103, k) from generate_series(0, 2) k;
select pg_temp.eq('grid: off with no gap before it keeps the first off minute',
  (select data from public.email_queue where plant_id = 9103 and kind = 'grid_down') - 'chargePct',
  jsonb_build_object('since', pg_temp.t(3720)));

rollback;
