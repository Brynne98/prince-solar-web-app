-- verify-0102: email triggers (SOLAR-183). Local stack only; one transaction, rolled back.
-- psql "$LOCAL_DB_URL" -X -q -f scripts/sql/verify-0102.sql   (exit 0 and ALL TESTS PASSED = pass)
\set ON_ERROR_STOP 1
begin;

create function pg_temp.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', what; end if;
  raise notice 'ok: %', what;
end $$;

-- local device time string for an epoch
create function pg_temp.dt(t bigint) returns text language sql as $$
  select to_char(timezone('Africa/Johannesburg', to_timestamp(t)), 'YYYY-MM-DD HH24:MI:SS') $$;

-- one reading row
create function pg_temp.rd(p bigint, sn text, t bigint, volt double precision, soc double precision default 60,
                           temp double precision default 30, dev bigint default null) returns void language sql as $$
  insert into public.readings (ts, sn, plant_id, device_time, grid_volt_v, batt_soc, batt_temp_c, carried)
  values (t, p || sn, p, pg_temp.dt(coalesce(dev, t)), volt, soc, temp, false) $$;

create function pg_temp.q(p bigint, k text) returns int language sql as $$
  select count(*)::int from public.email_queue where plant_id = p and kind = k $$;

-- Fixtures: two users on plant 990001 (grid/battery/strings), one on 990002 (never had grid).
insert into auth.users (id, email, email_confirmed_at, aud, role)
values ('00000000-0000-0000-0000-00000000a001', 't1@example.test', now(), 'authenticated', 'authenticated'),
       ('00000000-0000-0000-0000-00000000a002', 't2@example.test', now(), 'authenticated', 'authenticated'),
       ('00000000-0000-0000-0000-00000000a003', 't3@example.test', null,  'authenticated', 'authenticated');
insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, last_ok_at)
values ('00000000-0000-0000-0000-0000000ac001', '00000000-0000-0000-0000-00000000a001', 'u1', 'active', now()),
       ('00000000-0000-0000-0000-0000000ac002', '00000000-0000-0000-0000-00000000a002', 'u2', 'active', now()),
       ('00000000-0000-0000-0000-0000000ac003', '00000000-0000-0000-0000-00000000a003', 'u3', 'active', now());
insert into public.plant_users (plant_id, user_id, account_id, plant_name)
values (990001, '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-0000000ac001', 'Home'),
       (990001, '00000000-0000-0000-0000-00000000a002', '00000000-0000-0000-0000-0000000ac002', 'Mom'),
       (990002, '00000000-0000-0000-0000-00000000a003', '00000000-0000-0000-0000-0000000ac003', 'Farm');

insert into public.plant_config (plant_id, battery_banks) values (990001, 'per-inverter'), (990002, 'per-inverter');

-- Welcome: the two confirmed users at insert, the third when confirmed.
select pg_temp.ok((select count(*) from public.email_queue where kind = 'welcome' and user_id::text like '00000000-0000-0000-0000-00000000a00%') = 2, 'welcome queued for users confirmed at sign-up');
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-00000000a003';
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-00000000a003';
select pg_temp.ok((select count(*) from public.email_queue where kind = 'welcome' and user_id = '00000000-0000-0000-0000-00000000a003') = 1, 'welcome queued once on confirm');

-- ---------------------------------------------------------------- grid
-- 70 minutes ending 5 min ago: on 0-9, off 10-49 (one unknown minute at 20, slave stale
-- at 30-34 reading 230 V with an old device_time), on 50-59, off 60-61 (a 2-min blip),
-- on 62-69. Plant 990002 reads 0 V throughout.
do $$
declare b bigint := (extract(epoch from now())::bigint / 60) * 60 - 70 * 60; i int; t bigint; v double precision;
begin
  for i in 0..69 loop
    t := b + i * 60;
    v := case when i between 10 and 49 or i between 60 and 61 then 4 else 231 end;
    if i = 20 then v := null; end if;
    perform pg_temp.rd(990001, 'A', t, v, 60, 30);
    -- slave: stale device time (5 min old) and an old 230 V during 30-34; must not out-vote A
    perform pg_temp.rd(990001, 'B', t, case when i between 30 and 34 then 230 else v end, 60, 30,
                       case when i between 30 and 34 then t - 300 else t end);
    perform pg_temp.rd(990002, 'C', t, 0, 60, 30);
    perform public.email_poll_step(t, '[]', array[990001, 990002]::bigint[]);
    if i = 9 then perform pg_temp.ok(pg_temp.q(990001, 'grid_down') = 0, 'grid on at start: no email (first state is silent)'); end if;
    if i = 11 then perform pg_temp.ok(pg_temp.q(990001, 'grid_down') = 0, 'two off minutes: no Grid off yet'); end if;
    if i = 12 then perform pg_temp.ok(pg_temp.q(990001, 'grid_down') = 2, 'third off minute: Grid off queued for both users'); end if;
    if i = 49 then perform pg_temp.ok(pg_temp.q(990001, 'grid_down') = 2, 'long outage with an unknown minute and a stale slave: still one Grid off'); end if;
    if i = 50 then perform pg_temp.ok(pg_temp.q(990001, 'grid_back') = 0, 'one on minute: no Grid back yet'); end if;
    if i = 51 then perform pg_temp.ok(pg_temp.q(990001, 'grid_back') = 2, 'second on minute: Grid back queued'); end if;
  end loop;
  perform pg_temp.ok((select (data->>'since')::bigint = b + 600 from public.email_queue where kind = 'grid_down' and plant_id = 990001 limit 1), 'Grid off since = first off minute');
  perform pg_temp.ok((select (data->>'since')::bigint = b + 600 and (data->>'at')::bigint = b + 3000 from public.email_queue where kind = 'grid_back' and plant_id = 990001 limit 1), 'Grid back since/at = real outage times');
  perform pg_temp.ok((select pair_key from public.email_queue where kind = 'grid_back' and plant_id = 990001 limit 1) = 'grid_down:990001:' || (b + 600), 'Grid back is paired with its Grid off');
  perform pg_temp.ok(pg_temp.q(990001, 'grid_down') = 2, '2-min blip: no second Grid off');
  perform pg_temp.ok(pg_temp.q(990002, 'grid_down') + pg_temp.q(990002, 'grid_back') = 0, 'plant that never had grid: nothing');
  perform pg_temp.ok(pg_temp.q(990001, 'batt_hot') = 0 and pg_temp.q(990001, 'bank_drift') = 0, 'no battery emails at 30 C, equal charge');
end $$;

-- A Grid back with no Grid off sent (state taken silently) never queues: 990002 grid comes on.
do $$
declare b bigint := (extract(epoch from now())::bigint / 60) * 60 ; i int;
begin
  for i in 0..2 loop
    perform pg_temp.rd(990002, 'C', b + i * 60, 230, 60, 30);
    perform public.email_poll_step(b + i * 60, '[]', array[990002]::bigint[]);
  end loop;
  perform pg_temp.ok(pg_temp.q(990002, 'grid_back') = 0, 'grid switched on at a plant never told it was off: no Grid back');
end $$;

-- ---------------------------------------------------------------- battery + strings + drift
-- New plant 990003, 70 minutes: temps, a dead string, spread between two banks.
insert into public.plant_users (plant_id, user_id, account_id, plant_name)
values (990003, '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-0000000ac001', 'Shed');
insert into public.plant_config (plant_id, battery_banks) values (990003, 'per-inverter');
do $$
declare b bigint := (extract(epoch from now())::bigint / 60) * 60 - 75 * 60; i int; t bigint; temp double precision;
begin
  for i in 0..69 loop
    t := b + i * 60;
    temp := case when i < 5 then 39 when i < 10 then 41.4 when i < 15 then 39 when i < 20 then 37 when i < 25 then 41 else 35 end;
    perform pg_temp.rd(990003, 'A', t, 231, 72, temp);
    perform pg_temp.rd(990003, 'B', t, 231, 60, 30);
    -- string 1 makes 300 W; string 2 alive for 3 minutes, then dead
    insert into public.strings (ts, sn, no, plant_id, volt_v, power_w) values
      (t, 'A', 1, 990003, 350, 300),
      (t, 'A', 2, 990003, case when i < 3 then 340 else 0.4 end, case when i < 3 then 280 else 0 end);
    perform public.email_poll_step(t, '[]', array[990003]::bigint[]);
    if i = 14 then perform pg_temp.ok(pg_temp.q(990003, 'batt_hot') = 1, 'battery over 40 C: one email, not again while 38-40'); end if;
    if i = 13 then perform pg_temp.ok(pg_temp.q(990003, 'string_dead') = 0, '11 dead samples: no email yet'); end if;
    if i = 14 then perform pg_temp.ok(pg_temp.q(990003, 'string_dead') = 1, '12 dead samples in sun: one email'); end if;
    if i = 53 then perform pg_temp.ok(pg_temp.q(990003, 'bank_drift') = 0, 'spread under an hour: no email'); end if;
  end loop;
  perform pg_temp.ok(pg_temp.q(990003, 'batt_hot') = 2, 'cooled to 37 C, then over 40 C again: a second email');
  perform pg_temp.ok(pg_temp.q(990003, 'string_dead') = 1, 'dead string: one email, not one per minute');
  perform pg_temp.ok((select (data->>'since')::bigint = b + 3 * 60 from public.email_queue where kind = 'string_dead' and plant_id = 990003), 'Panels stopped since = minute after it last had voltage');
  perform pg_temp.ok(pg_temp.q(990003, 'bank_drift') = 1, '12 points apart for an hour: one email');
end $$;

-- Daily reminders: back-date the last email 25 h, sweep.
update private.plant_alert_state set hot = true, hot_sent_at = now() - interval '25 hours' where plant_id = 990003;
update private.plant_alert_state set drift_sent_at = now() - interval '25 hours' where plant_id = 990003;
update private.string_alert_state set sent_at = now() - interval '25 hours' where plant_id = 990003 and dead;
select public.email_sweep();
select pg_temp.ok(pg_temp.q(990003, 'batt_hot') = 3 and pg_temp.q(990003, 'bank_drift') = 2 and pg_temp.q(990003, 'string_dead') = 2, 'after 24 h still going: one reminder each');
select public.email_sweep();
select pg_temp.ok(pg_temp.q(990003, 'batt_hot') = 3 and pg_temp.q(990003, 'bank_drift') = 2 and pg_temp.q(990003, 'string_dead') = 2, 'sweep again at once: no second reminder');

-- Shared battery pack: no drift email.
update public.plant_config set battery_banks = 'shared' where plant_id = 990003;
update private.plant_alert_state set drift = false, drift_run_start = null where plant_id = 990003;
delete from public.email_queue where plant_id = 990003 and kind = 'bank_drift';
do $$
declare b bigint := (extract(epoch from now())::bigint / 60) * 60 - 4 * 60; i int;
begin
  for i in 0..3 loop
    perform pg_temp.rd(990003, 'A', b + i * 60, 231, 72, 30); perform pg_temp.rd(990003, 'B', b + i * 60, 231, 60, 30);
    perform public.email_poll_step(b + i * 60, '[]', array[990003]::bigint[]);
  end loop;
  perform pg_temp.ok((select drift_run_start is null from private.plant_alert_state where plant_id = 990003) and pg_temp.q(990003, 'bank_drift') = 0, 'shared pack: no drift tracking');
end $$;

-- ---------------------------------------------------------------- readings
-- 990001's newest reading is 5 min old. Make it 20 min old; poll tried its login just now.
update private.plant_alert_state set last_dev = extract(epoch from now())::bigint - 1200 where plant_id = 990001;
update private.sunsynk_accounts set last_try = 'ours', last_try_at = now() where user_id::text like '00000000-0000-0000-0000-00000000a00%';
select public.email_sweep();
select pg_temp.ok(pg_temp.q(990001, 'logger_stale') = 0, 'our own poll failing: no No readings');
update private.sunsynk_accounts set last_try = 'sunsynk', last_try_at = now() where id = '00000000-0000-0000-0000-0000000ac001';
select public.email_sweep();
select pg_temp.ok(pg_temp.q(990001, 'logger_stale') = 2, 'one login failing alone: No readings to both users');
select public.email_sweep();
select pg_temp.ok(pg_temp.q(990001, 'logger_stale') = 2, 'still stale: no second No readings');
do $$
declare t bigint := (extract(epoch from now())::bigint / 60) * 60;
begin
  perform pg_temp.rd(990001, 'A', t, 231);
  perform public.email_poll_step(t, '[]', array[990001]::bigint[]);
  perform pg_temp.ok(pg_temp.q(990001, 'logger_back') = 2, 'fresh reading: Readings back');
  perform pg_temp.ok((select (data->>'since')::bigint = extract(epoch from now())::bigint - 1200 from public.email_queue where kind = 'logger_back' and plant_id = 990001 limit 1), 'Readings back carries the stale time');
end $$;

-- ---------------------------------------------------------------- SunSynk
-- 3 test logins + every other local login. Fail the 3 test ones: down needs >= 3 and over half.
update private.sunsynk_accounts set last_try = 'ok', last_try_at = now(), last_ok_at = now() where user_id::text not like '00000000-0000-0000-0000-00000000a00%';
update private.sunsynk_accounts set last_try = 'sunsynk', last_try_at = now(), last_ok_at = now() - interval '12 minutes'
 where user_id::text like '00000000-0000-0000-0000-00000000a00%';
select public.email_sweep();
select pg_temp.ok((select sunsynk_down from private.email_system_state) =
                  ((select count(*) from private.sunsynk_accounts where status = 'active' and last_try_at > now() - interval '10 minutes') < 6),
                  'SunSynk down only when over half the tried logins fail');
-- force the fleet to just the 3 test logins plus one good one
update private.sunsynk_accounts set last_try_at = now() - interval '1 hour' where user_id::text not like '00000000-0000-0000-0000-00000000a00%';
update private.sunsynk_accounts set last_try_at = now(), last_try = 'ok', last_ok_at = now()
 where id = (select id from private.sunsynk_accounts where user_id::text not like '00000000-0000-0000-0000-00000000a00%' limit 1);
select public.email_sweep();
select pg_temp.ok((select sunsynk_down from private.email_system_state), '3 of 4 logins failing: SunSynk down');
select pg_temp.ok((select count(*) from public.email_queue where kind = 'sunsynk_down') = 3, 'SunSynk down: one email per user on a failing login');
select public.email_sweep();
select pg_temp.ok((select count(*) from public.email_queue where kind = 'sunsynk_down') = 3, 'still down: no second email');
update private.plant_alert_state set last_dev = extract(epoch from now())::bigint - 1200, stale = false where plant_id = 990003;
select public.email_sweep();
select pg_temp.ok(pg_temp.q(990003, 'logger_stale') = 0, 'SunSynk down: no per-plant No readings');
update private.sunsynk_accounts set last_try = 'ok', last_ok_at = now() where user_id::text like '00000000-0000-0000-0000-00000000a00%';
select public.email_sweep();
select pg_temp.ok((select count(*) from public.email_queue where kind = 'sunsynk_back') = 3 and not (select sunsynk_down from private.email_system_state), 'SunSynk back to the same users');

-- Just after an outage ends: readings it held up are old, but no No readings for 15 min.
update private.plant_alert_state set last_dev = extract(epoch from now())::bigint - 1500, stale = false where plant_id = 990002;
update private.sunsynk_accounts set last_try = 'sunsynk', last_try_at = now() where id = '00000000-0000-0000-0000-0000000ac003';
select public.email_sweep();
select pg_temp.ok(pg_temp.q(990002, 'logger_stale') = 0, 'within 15 min of SunSynk back: no No readings');
update private.email_system_state set up_at = now() - interval '16 minutes';
select public.email_sweep();
select pg_temp.ok(pg_temp.q(990002, 'logger_stale') = 1, '16 min after: No readings for a login still failing');

-- The same minute stepped twice (link kick and shard): strings counted once.
do $$
declare t bigint := (extract(epoch from now())::bigint / 60) * 60 + 600; n0 int; n1 int;
begin
  update public.plant_config set battery_banks = 'per-inverter' where plant_id = 990003;
  insert into public.strings (ts, sn, no, plant_id, volt_v, power_w) values (t, 'A', 1, 990003, 350, 300), (t, 'A', 3, 990003, 0, 0);
  perform pg_temp.rd(990003, 'A', t, 231);
  perform public.email_poll_step(t, '[]', array[990003]::bigint[]);
  select dead_n into n0 from private.string_alert_state where plant_id = 990003 and sn = 'A' and no = 3;
  perform public.email_poll_step(t, '[]', array[990003]::bigint[]);
  select dead_n into n1 from private.string_alert_state where plant_id = 990003 and sn = 'A' and no = 3;
  perform pg_temp.ok(n0 = 1 and n1 = 1, 'same minute stepped twice: one dead sample');
end $$;

-- ---------------------------------------------------------------- history, Reconnect
update public.plant_config set backfill_next = current_date - 60, temp_next = current_date - 60 where plant_id = 990002;
update public.plant_config set backfill_next = null where plant_id = 990002;
select pg_temp.ok(pg_temp.q(990002, 'history') = 0, 'spine done, temperatures not: no history yet');
update public.plant_config set temp_next = current_date where plant_id = 990002;
select pg_temp.ok(pg_temp.q(990002, 'history') = 1, 'both walks done: history queued');
update public.plant_config set temp_next = current_date + 1 where plant_id = 990002;
select pg_temp.ok(pg_temp.q(990002, 'history') = 1, 'later walk updates: no second history');
insert into public.plant_users (plant_id, user_id, account_id, plant_name)
values (990002, '00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-0000000ac001', 'Farm');
select pg_temp.ok(pg_temp.q(990002, 'history') = 2, 'a user joining a plant already done: history for them');

update private.sunsynk_accounts set status = 'needs_relink' where id = '00000000-0000-0000-0000-0000000ac002';
update private.sunsynk_accounts set status = 'needs_relink', last_error = 'again' where id = '00000000-0000-0000-0000-0000000ac002';
select pg_temp.ok((select count(*) from public.email_queue where kind = 'needs_relink' and user_id = '00000000-0000-0000-0000-00000000a002' and plant_id = 990001) = 1, 'login dies: one Reconnect naming its own plant');

-- ---------------------------------------------------------------- reports
-- The sweep's report rule against fixed local times (same expression as email_sweep).
select pg_temp.ok((
  select array_agg(p.period order by p.period)::text from (values (timestamp '2027-01-04 07:00')) x(t),
         lateral (values ('week'), ('month'), ('year')) p(period)
   where extract(hour from x.t) >= 7 and case p.period when 'week' then extract(isodow from x.t) = 1
                                                       when 'month' then extract(day from x.t) = 1
                                                       else extract(day from x.t) = 1 and extract(month from x.t) = 1 end) = '{week}',
  'Monday 4 Jan: weekly only');
select pg_temp.ok((
  select array_agg(p.period order by p.period)::text from (values (timestamp '2027-02-01 23:59')) x(t),
         lateral (values ('week'), ('month'), ('year')) p(period)
   where extract(hour from x.t) >= 7 and case p.period when 'week' then extract(isodow from x.t) = 1
                                                       when 'month' then extract(day from x.t) = 1
                                                       else extract(day from x.t) = 1 and extract(month from x.t) = 1 end) = '{month,week}',
  'Monday 1 Feb at 23:59: weekly and monthly still due');

-- ---------------------------------------------------------------- claim rules
-- Switch off grid for user 2; remove user 1 from 990003; a back with no down.
insert into public.email_prefs (user_id, grid) values ('00000000-0000-0000-0000-00000000a002', false);
delete from public.plant_users where plant_id = 990003;
insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data)
values ('00000000-0000-0000-0000-00000000a003', 990002, 'grid_back', 'grid_back:test', 'grid_down:never', '{"since":1,"at":2}');
update public.email_queue set due_at = now() - interval '1 minute' where status = 'queued';
create temp table claimed as select * from public.email_claim(100000);
select pg_temp.ok((select status from public.email_queue where key = 'grid_back:test') = 'skipped', 'Grid back whose Grid off never went: skipped');
select pg_temp.ok((select count(*) from public.email_queue where user_id = '00000000-0000-0000-0000-00000000a002' and kind like 'grid%' and status = 'skipped') = 2, 'grid switched off: that user''s grid emails skipped');
select pg_temp.ok((select count(*) from public.email_queue where plant_id = 990003 and status = 'skipped' and last_error = 'plant removed') > 0, 'plant removed: its emails skipped');
select pg_temp.ok((select count(*) from public.email_queue where kind = 'welcome' and user_id = '00000000-0000-0000-0000-00000000a001' and last_error = 'plant linked') = 1, 'welcome after a plant is linked: skipped');
select pg_temp.ok((select count(*) from claimed c where c.kind = 'grid_down' and c.plant_name = 'Home' and c.unsub_token is not null) = 1, 'claimed row carries the user''s plant name and unsubscribe token');
select pg_temp.ok((select count(*) from public.email_claim(100000)) = 0, 'claimed rows are not claimed twice');
select public.email_done(jsonb_build_array(jsonb_build_object('id', (select id from claimed limit 1), 'status', 'queued', 'retry_s', 120)));
select pg_temp.ok((select due_at > now() + interval '100 seconds' from public.email_queue where id = (select id from claimed limit 1)), 'temporary failure: back on the queue with a wait');

-- A deleted account's address goes once its email is done with.
insert into public.email_queue (to_email, kind, key, status, claimed_at) values ('gone@example.test', 'account_deleted', 'account_deleted:test', 'sending', now());
select public.email_done(jsonb_build_array(jsonb_build_object('id', (select id from public.email_queue where key = 'account_deleted:test'), 'status', 'sent')));
select pg_temp.ok(not exists (select 1 from public.email_queue where to_email = 'gone@example.test'), 'account deleted: address removed after send');

rollback;
\echo ALL TESTS PASSED
