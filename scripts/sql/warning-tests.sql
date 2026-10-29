-- Warning email tests (SOLAR-231): does each email fire on a real problem and stay quiet
-- on real normal data? Feeds minutes shaped like recorded production rows to
-- email_poll_step and email_sweep, inside one transaction that is rolled back.
--   psql "$DB_URL" -f scripts/sql/warning-tests.sql      (local database only)
-- Exit code decides: any wrong case raises. A known wrong answer, kept so its fix can be
-- proven, prints GAP and does not fail; when it starts passing it prints FIXED.
\set QUIET on
\set ON_ERROR_STOP on
begin;

-- Never on a live database: email_sweep locks and steps every plant. A login that polled
-- in the last hour means a poller is running here.
do $$ begin
  if exists (select 1 from private.sunsynk_accounts where last_ok_at > now() - interval '1 hour')
     or exists (select 1 from public.plant_config where plant_id between 9001 and 9007) then
    raise exception 'refused: this looks like a live database';
  end if;
end $$;

create function pg_temp.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is distinct from want then raise exception 'FAIL %: got %, want %', label, got, want; end if;
  raise notice 'PASS  %', label;
end $$;
create function pg_temp.gap(label text, ok boolean, why text) returns void language plpgsql as $$
begin
  if ok then raise notice 'FIXED %: passes now, make it a plain case', label;
  else raise notice 'GAP   %: %', label, why; end if;
end $$;

-- Times: minutes counted back from now, so they land in a live partition and email_sweep's
-- clock agrees. T(k) is k minutes after the start, two hours ago.
create function pg_temp.t(k int) returns bigint language sql as
  $$ select (extract(epoch from now())::bigint / 60) * 60 - 7200 + k * 60 $$;
create function pg_temp.dt(ts bigint) returns text language sql as
  $$ select to_char(to_timestamp(ts) at time zone 'Africa/Johannesburg', 'YYYY-MM-DD HH24:MI:SS') $$;
-- One inverter's row for one minute. dev_lag: how many seconds old its device_time is.
-- Serials are unique across plants (the key is ts, sn), so each takes its plant's number.
create function pg_temp.r(p bigint, k int, sn text, volt numeric, temp numeric default 25, soc numeric default 80, dev_lag int default 30)
returns void language sql as $$
  insert into public.readings (ts, sn, plant_id, carried, device_time, grid_volt_v, batt_temp_c, batt_soc)
  values (pg_temp.t(k), p || sn, p, false, case when dev_lag is not null then pg_temp.dt(pg_temp.t(k) - dev_lag) end, volt, temp, soc)
$$;
-- One poll minute for every test plant; a rule that throws is a failure, not a quiet minute.
create function pg_temp.step_at(ts bigint) returns void language plpgsql as $$
declare res jsonb := public.email_poll_step(ts, '[]', array[9001, 9002, 9003, 9004, 9005, 9006, 9007]::bigint[]);
begin
  if jsonb_array_length(res->'failed') > 0 then raise exception 'FAIL email_poll_step: %', res->'failed'; end if;
end $$;
create function pg_temp.step(k int) returns void language sql as $$ select pg_temp.step_at(pg_temp.t(k)) $$;
create function pg_temp.sent(p bigint, k text) returns int language sql as
  $$ select count(*)::int from public.email_queue where plant_id = p and kind = k $$;
-- Test logins only: the local database may hold others.
create function pg_temp.logins(outcome text, at timestamptz, ok_at timestamptz default null, who text default 'w900%')
returns void language sql as $$
  update private.sunsynk_accounts set last_try = outcome, last_try_at = at, last_ok_at = ok_at where sunsynk_username like who
$$;

-- One owner and login per plant: a free plan holds one plant and pauses the rest, and a
-- paused plant gets no email. Users first: plant_row_guard drops rows of an ownerless plant.
insert into auth.users (id, email)
  select ('00000000-0000-0000-0000-00000000' || p)::uuid, p || '@t.test' from unnest(array[9001, 9002, 9003, 9004, 9005, 9006, 9007]) p;
insert into private.sunsynk_accounts (id, user_id, sunsynk_username, last_try, last_try_at)
  select ('00000000-0000-0000-0000-0000000a' || p)::uuid, ('00000000-0000-0000-0000-00000000' || p)::uuid, 'w' || p, 'ok', now()
    from unnest(array[9001, 9002, 9003, 9004, 9005, 9006, 9007]) p;
insert into public.plant_users (plant_id, user_id, account_id)
  select p, ('00000000-0000-0000-0000-00000000' || p)::uuid, ('00000000-0000-0000-0000-0000000a' || p)::uuid
    from unnest(array[9001, 9002, 9003, 9004, 9005, 9006, 9007]) p;
insert into public.plant_config (plant_id, has_battery, battery_banks)
  select p, true, 'shared' from unnest(array[9001, 9002, 9003, 9004, 9005, 9006, 9007]) p;

-- ---- Grid (plant 9001: master M, slave S, both sense mains) ----------------------------
-- Minutes 0-4 grid on (the first state is taken silently), 5-6 off (a 2-minute dip,
-- as 495944 recorded), 7-9 on, 10-14 off with no voltage from either inverter at 11
-- (half-failed answers, as on 538820 on 29 Oct), 15-19 on. The unknown minute neither
-- counts as off nor ends the run: Grid off goes at 13, the third known off minute.
do $$ begin
  for k in 0..19 loop
    perform pg_temp.r(9001, k, 'M', case when k = 11 then null when k in (5, 6) or k between 10 and 14 then 0.0 else 239.3 end);
    perform pg_temp.r(9001, k, 'S', case when k = 11 then null when k in (5, 6) or k between 10 and 14 then 0.0 else 238.7 end, -100, 80, 200);
    perform pg_temp.step(k);
    if k = 9 then perform pg_temp.eq('grid: a 2-minute dip sends no Grid off', pg_temp.sent(9001, 'grid_down'), 0); end if;
    if k = 12 then perform pg_temp.eq('grid: 2 off minutes and 1 unknown send nothing yet', pg_temp.sent(9001, 'grid_down'), 0); end if;
  end loop;
end $$;
select pg_temp.eq('grid: 3 off minutes around an unknown one send one Grid off', pg_temp.sent(9001, 'grid_down'), 1);
select pg_temp.eq('grid: back for 2 minutes sends one Grid back', pg_temp.sent(9001, 'grid_back'), 1);

-- Plant 9002: the 18 Sep lesson. The slave's logger froze at 240.1 V with an old
-- device_time while the master, newest, read 0 V. Off for 4 minutes: Grid off.
do $$ begin
  for k in 0..2 loop perform pg_temp.r(9002, k, 'M', 240.0); perform pg_temp.r(9002, k, 'S', 240.1, -100); perform pg_temp.step(k); end loop;
  for k in 3..6 loop perform pg_temp.r(9002, k, 'M', 0.0); perform pg_temp.r(9002, k, 'S', 240.1, -100, 80, 30 + (k - 2) * 60); perform pg_temp.step(k); end loop;
end $$;
select pg_temp.eq('grid: a frozen logger at 240 V does not hide a real outage', pg_temp.sent(9002, 'grid_down'), 1);

-- Plant 9003: an inverter that does not sense mains (reads 0 V always) and one that does
-- (239 V). Which one uploaded last changes minute to minute (on 538820 the slave was the
-- newest alone in 594 of 5405 minutes). No plant has a blind inverter yet; a three-phase one can.
do $$ begin
  for k in 0..6 loop
    perform pg_temp.r(9003, k, 'M', 239.0, 25, 80, case when k < 3 then 10 else 90 end);
    perform pg_temp.r(9003, k, 'S', 0.0, -100, 80, case when k < 3 then 90 else 10 end);
    perform pg_temp.step(k);
  end loop;
end $$;
select pg_temp.gap('grid: an inverter that cannot see mains does not decide Grid off', pg_temp.sent(9003, 'grid_down') = 0,
  'presence reads only the newest device_time, so a blind newer inverter outvotes one that sees 239 V');

-- ---- Battery hot (plant 9004: master reads the pack, slave -100) -----------------------
do $$ begin
  for k in 0..2 loop perform pg_temp.r(9004, k, 'M', 239, 29); perform pg_temp.r(9004, k, 'S', 239, -100); perform pg_temp.step(k); end loop;
  -- 05:17 on 29 Oct: a half-failed answer stored 0 °C and 0 %; not hot, not cold
  perform pg_temp.r(9004, 3, 'M', 239, 0, 0); perform pg_temp.r(9004, 3, 'S', 239, -100); perform pg_temp.step(3);
end $$;
select pg_temp.eq('hot: 29 °C, -100 slaves and a 0 °C half-failed row send nothing', pg_temp.sent(9004, 'batt_hot'), 0);
-- One warm minute, then two: not hot. Three minutes over 45 °C: hot (0119).
do $$ begin
  perform pg_temp.r(9004, 4, 'M', 239, 47); perform pg_temp.r(9004, 4, 'S', 239, -100); perform pg_temp.step(4);
  for k in 5..7 loop perform pg_temp.r(9004, k, 'M', 239, 30); perform pg_temp.r(9004, k, 'S', 239, -100); perform pg_temp.step(k); end loop;
end $$;
select pg_temp.eq('hot: one minute at 47 °C sends nothing', pg_temp.sent(9004, 'batt_hot'), 0);
do $$ begin
  for k in 8..10 loop perform pg_temp.r(9004, k, 'M', 239, case when k < 10 then 47 else 41 end); perform pg_temp.r(9004, k, 'S', 239, -100); perform pg_temp.step(k); end loop;
end $$;
select pg_temp.eq('hot: two minutes at 47 °C, then 41 °C, sends nothing', pg_temp.sent(9004, 'batt_hot'), 0);
do $$ begin
  for k in 11..13 loop perform pg_temp.r(9004, k, 'M', 239, 46); perform pg_temp.r(9004, k, 'S', 239, -100); perform pg_temp.step(k); end loop;
end $$;
select pg_temp.eq('hot: three minutes at 46 °C sends one Battery hot', pg_temp.sent(9004, 'batt_hot'), 1);
-- Cooling to 44 °C is still the same hot spell; 43 °C ends it; a new spell emails again.
do $$ begin
  perform pg_temp.r(9004, 14, 'M', 239, 44); perform pg_temp.r(9004, 14, 'S', 239, -100); perform pg_temp.step(14);
  for k in 15..17 loop perform pg_temp.r(9004, k, 'M', 239, 46); perform pg_temp.r(9004, k, 'S', 239, -100); perform pg_temp.step(k); end loop;
end $$;
select pg_temp.eq('hot: back to 46 °C after 44 °C sends no second email', pg_temp.sent(9004, 'batt_hot'), 1);
do $$ begin
  perform pg_temp.r(9004, 18, 'M', 239, 43); perform pg_temp.r(9004, 18, 'S', 239, -100); perform pg_temp.step(18);
  for k in 19..21 loop perform pg_temp.r(9004, k, 'M', 239, 46); perform pg_temp.r(9004, k, 'S', 239, -100); perform pg_temp.step(k); end loop;
end $$;
select pg_temp.eq('hot: after 43 °C, three more minutes at 46 °C send a second email', pg_temp.sent(9004, 'batt_hot'), 2);
-- 45.3 °C is hot in the app (over 45), so in the email too: not rounded down to 45.
do $$ begin
  perform pg_temp.r(9004, 22, 'M', 239, 30); perform pg_temp.r(9004, 22, 'S', 239, -100); perform pg_temp.step(22);
  for k in 23..25 loop perform pg_temp.r(9004, k, 'M', 239, 45.3); perform pg_temp.r(9004, k, 'S', 239, -100); perform pg_temp.step(k); end loop;
end $$;
select pg_temp.eq('hot: three minutes at 45.3 °C send a third email', pg_temp.sent(9004, 'batt_hot'), 3);
-- Two hot minutes, 5 minutes with no row, one hot minute: not three in a row.
do $$ begin
  perform pg_temp.r(9004, 26, 'M', 239, 30); perform pg_temp.r(9004, 26, 'S', 239, -100); perform pg_temp.step(26);
  for k in 27..28 loop perform pg_temp.r(9004, k, 'M', 239, 47); perform pg_temp.r(9004, k, 'S', 239, -100); perform pg_temp.step(k); end loop;
  perform pg_temp.r(9004, 34, 'M', 239, 47); perform pg_temp.r(9004, 34, 'S', 239, -100); perform pg_temp.step(34);
end $$;
select pg_temp.eq('hot: two hot minutes, a 5-minute gap, one more: no email', pg_temp.sent(9004, 'batt_hot'), 3);

-- ---- Strings (plant 9005: master M, inputs 1 and 2) -------------------------------------
-- Input 1 as on 538820 since 25 Oct: about 1 V, 0 W, never made power. Input 2 makes power.
create function pg_temp.s(k int, sn text, no int, volt numeric, w numeric) returns void language sql as $$
  insert into public.strings (ts, sn, no, plant_id, volt_v, power_w) values (pg_temp.t(k), '9005' || sn, no, 9005, volt, w)
$$;
do $$ begin
  for k in 0..19 loop
    perform pg_temp.r(9005, k, 'M', 239);
    perform pg_temp.s(k, 'M', 1, 1.0, 0); perform pg_temp.s(k, 'M', 2, 241.6, 1800);
    perform pg_temp.step(k);
  end loop;
end $$;
select pg_temp.eq('strings: an input with no panels sends nothing (SOLAR-188)', pg_temp.sent(9005, 'string_dead'), 0);
-- Input 3 makes 2.9 kW, reads 1 V for 8 minutes while input 2 makes power, recovers for
-- a minute, is dead 8 more (16 dead in 17: the count must restart on recovery), recovers,
-- then drops for 13 minutes.
do $$ begin
  for k in 20..59 loop
    perform pg_temp.r(9005, k, 'M', 239);
    perform pg_temp.s(k, 'M', 2, 241.6, 1800);
    perform pg_temp.s(k, 'M', 3, case when k between 21 and 28 or k between 30 and 37 or k between 40 and 52 then 1.0 else 290 end,
                                 case when k between 21 and 28 or k between 30 and 37 or k between 40 and 52 then 0 else 2900 end);
    perform pg_temp.step(k);
    if k = 39 then perform pg_temp.eq('strings: two 8-minute drops with a minute alive between send nothing', pg_temp.sent(9005, 'string_dead'), 0); end if;
  end loop;
end $$;
select pg_temp.eq('strings: an input that made power, dead 13 minutes, sends one email', pg_temp.sent(9005, 'string_dead'), 1);
select pg_temp.gap('strings: an input broken before it ever made power is reported',
  exists (select 1 from public.email_queue where plant_id = 9005 and kind = 'string_dead' and key like 'string_dead:9005:9005M:1:%'),
  'by design since SOLAR-188: an input that never made 200 W is never checked');

-- ---- No readings (logger_stale, email_sweep) --------------------------------------------
-- The inverters SunSynk lists for each plant (an inverter no longer listed is left alone).
insert into private.inverters (sn, plant_id, account_id)
  select p || x, p, ('00000000-0000-0000-0000-0000000a' || p)::uuid from unnest(array[9001, 9006, 9007]) p, unnest(array['M', 'S']) x;
-- Plant 9001: the slave's logger stops 20 minutes before now while the master keeps
-- uploading. One inverter has gone quiet.
create function pg_temp.now_k(back_min int) returns bigint language sql as
  $$ select (extract(epoch from now())::bigint / 60) * 60 - back_min * 60 $$;
create function pg_temp.r_at(p bigint, ts bigint, sn text, volt numeric, dev bigint) returns void language sql as $$
  insert into public.readings (ts, sn, plant_id, carried, device_time, grid_volt_v, batt_temp_c, batt_soc)
  values (ts, p || sn, p, false, pg_temp.dt(dev), volt, 25, 80)
$$;
do $$ declare ts bigint; begin
  for back in reverse 20..1 loop
    ts := pg_temp.now_k(back);
    perform pg_temp.r_at(9001, ts, 'M', 239.3, ts - 30);
    perform pg_temp.r_at(9001, ts, 'S', 238.7, pg_temp.now_k(21));
    -- Plants 9006 and 9007: the whole logger stopped 14 and 16 minutes ago.
    perform pg_temp.r_at(9006, ts, 'M', 239.3, least(ts - 30, pg_temp.now_k(14)));
    perform pg_temp.r_at(9007, ts, 'M', 239.3, least(ts - 30, pg_temp.now_k(16)));
    perform pg_temp.step_at(ts);
  end loop;
end $$;
select pg_temp.logins('ok', now(), now());
select public.email_sweep();
select pg_temp.eq('no readings: an inverter quiet for 20 minutes beside a live one sends one email',
  (select count(*)::int from public.email_queue where plant_id = 9001 and kind = 'logger_stale' and data->>'inverter' = 'Inverter 9001S'), 1);
select pg_temp.eq('no readings: a plant quiet 16 minutes sends no per-inverter email as well',
  (select count(*)::int from public.email_queue where plant_id = 9007 and kind = 'logger_stale' and data ? 'inverter'), 0);
-- The slave's logger comes back: Readings back for it.
do $$ declare ts bigint := pg_temp.now_k(0); begin
  perform pg_temp.r_at(9001, ts, 'M', 239.3, ts - 30);
  perform pg_temp.r_at(9001, ts, 'S', 238.7, ts - 20);
  perform pg_temp.step_at(ts);
end $$;
select pg_temp.eq('no readings: the quiet inverter reporting again sends one Readings back',
  (select count(*)::int from public.email_queue where plant_id = 9001 and kind = 'logger_back' and data->>'inverter' = 'Inverter 9001S'), 1);
select pg_temp.eq('no readings: a plant quiet 14 minutes sends nothing', pg_temp.sent(9006, 'logger_stale'), 0);
select pg_temp.eq('no readings: a plant quiet 16 minutes sends one email', pg_temp.sent(9007, 'logger_stale'), 1);

-- ---- SunSynk down -----------------------------------------------------------------------
-- One login, failing for 20 minutes; the others not tried (as with two users, one down).
select pg_temp.logins('ok', now() - interval '1 hour', now() - interval '1 hour', '%');  -- every local login, rolled back
select pg_temp.logins('sunsynk', now(), now() - interval '20 minutes', 'w9001');
select public.email_sweep();
select pg_temp.eq('SunSynk down: the only login failing for 20 minutes is reported', (select sunsynk_down from private.email_system_state), true);
-- Two logins tried, one failing: that login's trouble, not SunSynk's.
select pg_temp.logins('ok', now(), now(), 'w9002');
select public.email_sweep();
select pg_temp.eq('SunSynk down: one of two logins failing is not SunSynk down', (select sunsynk_down from private.email_system_state), false);

rollback;
