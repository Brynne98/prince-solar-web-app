-- verify-0124: the Notifications list and pop-up claims (SOLAR-244). Local stack only;
-- one transaction, rolled back.
-- psql "$LOCAL_DB_URL" -X -q -f scripts/sql/verify-0124.sql   (exit code decides)
\set ON_ERROR_STOP 1
begin;

create function pg_temp.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', what; end if;
  raise notice 'ok: %', what;
end $$;
create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- Two users on plant 990101, a third on 990102 (Free keeps one plant per account).
insert into auth.users (id, email, email_confirmed_at, aud, role)
values ('00000000-0000-0000-0000-00000000b001', 'p1@example.test', now(), 'authenticated', 'authenticated'),
       ('00000000-0000-0000-0000-00000000b002', 'p2@example.test', now(), 'authenticated', 'authenticated'),
       ('00000000-0000-0000-0000-00000000b003', 'p3@example.test', now(), 'authenticated', 'authenticated');
insert into public.plant_users (plant_id, user_id, plant_name)
values (990101, '00000000-0000-0000-0000-00000000b001', 'Kloof St'),
       (990101, '00000000-0000-0000-0000-00000000b002', 'Mom'),
       (990102, '00000000-0000-0000-0000-00000000b003', 'Farm');
-- the pass that already ran: nothing older than this test is due
update public.email_queue set pushed_at = now(), push_skip = 'test' where pushed_at is null;

-- 17:42 to 19:15 SAST on 2025-10-28: an outage, its Grid back, a hot battery, a welcome.
select private.email_enqueue_plant(990101, 'grid_down', 'grid_down:990101:t', jsonb_build_object('since', 1761666120, 'chargePct', 62));
select private.email_enqueue_plant(990101, 'grid_back', 'grid_back:990101:t', jsonb_build_object('since', 1761666120, 'at', 1761671700), 'grid_down:990101:t');
select private.email_enqueue_plant(990102, 'batt_hot', 'batt_hot:990102:t', jsonb_build_object('at', 1761657900, 'tempC', 47));
insert into public.email_queue (user_id, kind, key) values ('00000000-0000-0000-0000-00000000b001', 'welcome', 'welcome:t');
-- sent earlier: the hot battery yesterday, the outage hours ago
update public.email_queue set created_at = now() - interval '3 hours' where key = 'grid_down:990101:t';
update public.email_queue set created_at = now() - interval '2 hours' where key = 'grid_back:990101:t';
update public.email_queue set created_at = now() - interval '1 day' where key = 'batt_hot:990102:t';

do $$
declare t jsonb := private.alert_text('grid_down', jsonb_build_object('since', 1761666120, 'chargePct', 62), to_timestamp(1761666300), 'Africa/Johannesburg');
begin
  perform pg_temp.ok(t->>'title' = 'Grid down' and t->>'body' = 'Off since 17:42. Battery 62%, running the house.', 'grid down words: ' || t::text);
  perform pg_temp.ok(t->>'day' = '2025-10-28' and t->>'time' = '17:42' and t->>'tab' = 'grid', 'grid down day, time and page');
  t := private.alert_text('grid_back', jsonb_build_object('since', 1761666120, 'at', 1761671700), to_timestamp(1761671760), 'Africa/Johannesburg');
  perform pg_temp.ok(t->>'body' = 'On again, after 1 h 33 min without grid.', 'grid back lasted: ' || (t->>'body'));
  t := private.alert_text('grid_down', jsonb_build_object('since', 1761666120), to_timestamp(1761666300), 'Africa/Johannesburg');
  perform pg_temp.ok(t->>'body' = 'Off since 17:42.', 'grid down without a charge reading');
  t := private.alert_text('string_dead', jsonb_build_object('string', 'String 3', 'inverter', 'Inverter 1', 'since', 1761469200), to_timestamp(1761645600), 'Africa/Johannesburg');
  perform pg_temp.ok(t->>'day' = '2025-10-28' and t->>'tab' = 'solar', 'a daily reminder takes its own day');
  t := private.alert_text('logger_stale', jsonb_build_object('since', 1761666120, 'inverter', 'Inverter 2'), to_timestamp(1761667020), 'Africa/Johannesburg');
  perform pg_temp.ok(t->>'title' = 'No readings from Inverter 2' and t->>'tab' = 'live', 'one inverter silent');
  t := private.alert_text('bank_drift', jsonb_build_object('since', 1761666120, 'banks', jsonb_build_array(
         jsonb_build_object('name', 'Inverter 1', 'chargePct', 72), jsonb_build_object('name', 'Inverter 2', 'chargePct', 60))), now(), 'Africa/Johannesburg');
  perform pg_temp.ok(t->>'body' = 'Inverter 1 72%, Inverter 2 60%. Over an hour apart.' and t->>'tab' = 'inverters', 'uneven batteries');
  perform pg_temp.ok(private.alert_text('welcome', '{}', now(), 'Africa/Johannesburg') is null, 'not an alert: no words');
end $$;

-- ---------------------------------------------------------------- the list
select pg_temp.as_user('00000000-0000-0000-0000-00000000b002');
do $$
declare n jsonb := public.api_notifications();
begin
  perform pg_temp.ok(jsonb_array_length(n->'items') = 2 and (n->>'unread')::int = 2 and n->'pinned' = '[]', 'user 2 sees its 2 alerts, unread');
  perform pg_temp.ok(n->'items'->0->>'kind' = 'grid_back' and n->'items'->0->>'plantName' = 'Mom', 'newest first, their own plant name');
  perform pg_temp.ok(not (n->'items' @> '[{"kind":"welcome"}]'), 'no welcome in the list');
end $$;
select public.api_notifications_read(array[(select id from public.email_queue where key = 'grid_down:990101:t' and user_id = '00000000-0000-0000-0000-00000000b002')]);
select pg_temp.ok((public.api_notifications()->>'unread')::int = 1, 'one marked read');
-- user 2 can't mark user 1's
select public.api_notifications_read(array(select id from public.email_queue where user_id = '00000000-0000-0000-0000-00000000b001'));
select pg_temp.ok((select count(*) = 0 from public.email_queue where user_id = '00000000-0000-0000-0000-00000000b001' and read_at is not null), 'another user''s alerts untouched');
select public.api_notifications_read(null);
select pg_temp.ok((public.api_notifications()->>'unread')::int = 0, 'mark all read');
-- a plant left: its alerts leave the list
select pg_temp.as_user('00000000-0000-0000-0000-00000000b003');
select pg_temp.ok(jsonb_array_length(public.api_notifications()->'items') = 1, 'user 3 sees the hot battery');
delete from public.plant_users where plant_id = 990102 and user_id = '00000000-0000-0000-0000-00000000b003';
select pg_temp.ok(jsonb_array_length(public.api_notifications()->'items') = 0, 'removed plant: its alerts gone');
select pg_temp.as_user('00000000-0000-0000-0000-00000000b001');
select pg_temp.ok((public.api_notifications()->>'unread')::int = 2, 'user 1 still has 2 unread');
select set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------- pop-ups
-- Recent again, so not "too old". User 1 has a browser; user 2 has none.
update public.email_queue set created_at = now() where key like 'grid_%:990101:t';
select public.push_done('{}', '{}');
insert into public.push_subs (user_id, endpoint, p256dh, auth)
values ('00000000-0000-0000-0000-00000000b001', 'https://push.test/1', 'k', 'a');

create temp table got as select * from public.push_claim(200);
select pg_temp.ok((select count(*) = 1 from got) and (select kind = 'grid_down' and title = 'Grid down at Kloof St' and tab = 'grid' and day is not null from got),
                  'first pass: Grid down for user 1 only; its back waits');
select pg_temp.ok((select subs->0->>'endpoint' = 'https://push.test/1' from got), 'with the browser');
select pg_temp.ok((select push_skip = 'no device' from public.email_queue where key = 'grid_down:990101:t' and user_id = '00000000-0000-0000-0000-00000000b002'), 'no browser: skipped');
select pg_temp.ok((select push_skip = 'not an alert' from public.email_queue where key = 'welcome:t'), 'welcome never pops up');
drop table got;
create temp table got as select * from public.push_claim(200);
select pg_temp.ok((select count(*) = 1 from got where kind = 'grid_back'), 'second pass: Grid back for user 1');
select pg_temp.ok((select push_skip = 'no device' from public.email_queue where key = 'grid_back:990101:t' and user_id = '00000000-0000-0000-0000-00000000b002'), 'no browser: its back skipped too');
drop table got;
select pg_temp.ok((select count(*) = 0 from public.push_claim(200)), 'nothing twice');

-- Switch off: no pop-up.
insert into public.push_prefs (user_id, grid) values ('00000000-0000-0000-0000-00000000b001', false);
select private.email_enqueue_plant(990101, 'grid_down', 'grid_down:990101:t2', jsonb_build_object('since', extract(epoch from now())::bigint));
select private.email_enqueue_plant(990101, 'logger_stale', 'logger_stale:990101:t2', jsonb_build_object('since', extract(epoch from now())::bigint));
create temp table got as select * from public.push_claim(200);
select pg_temp.ok((select count(*) = 1 from got where kind = 'logger_stale') and not exists (select 1 from got where kind = 'grid_down'), 'grid switched off: only the readings alert');
select pg_temp.ok((select push_skip = 'switched off' from public.email_queue where key = 'grid_down:990101:t2' and user_id = '00000000-0000-0000-0000-00000000b001'), 'marked switched off');
drop table got;
-- Switched on again mid-outage: its Grid back has no Grid down before it, so no pop-up.
update public.push_prefs set grid = true where user_id = '00000000-0000-0000-0000-00000000b001';
select private.email_enqueue_plant(990101, 'grid_back', 'grid_back:990101:t2', jsonb_build_object('since', extract(epoch from now())::bigint - 600, 'at', extract(epoch from now())::bigint), 'grid_down:990101:t2');
select pg_temp.ok((select count(*) = 0 from public.push_claim(200)), 'switched on mid-outage: nothing to send');
select pg_temp.ok((select push_skip = 'down had no pop-up' from public.email_queue where key = 'grid_back:990101:t2' and user_id = '00000000-0000-0000-0000-00000000b001'), 'no Grid back without its Grid down');

-- Too old: an alert from over an hour ago doesn't pop up late.
select private.email_enqueue_plant(990101, 'batt_hot', 'batt_hot:990101:t3', jsonb_build_object('at', 1761657900, 'tempC', 47));
update public.email_queue set created_at = now() - interval '2 hours' where key = 'batt_hot:990101:t3';
select pg_temp.ok((select count(*) = 0 from public.push_claim(200)), 'too old: nothing to send');
select pg_temp.ok((select push_skip = 'too old' from public.email_queue where key = 'batt_hot:990101:t3' and user_id = '00000000-0000-0000-0000-00000000b001'), 'too old: skipped');

-- Gone devices go; good ones get last_ok_at.
insert into public.push_subs (user_id, endpoint, p256dh, auth) values ('00000000-0000-0000-0000-00000000b001', 'https://push.test/2', 'k', 'a');
select public.push_done(array['https://push.test/1'], array['https://push.test/2']);
select pg_temp.ok((select last_ok_at is not null from public.push_subs where endpoint = 'https://push.test/1')
                  and not exists (select 1 from public.push_subs where endpoint = 'https://push.test/2'), 'push_done');

-- A second account on the same browser takes the endpoint over.
select pg_temp.as_user('00000000-0000-0000-0000-00000000b002');
select public.api_push_sub('https://push.test/1', 'k2', 'a2');
select pg_temp.ok((select user_id = '00000000-0000-0000-0000-00000000b002' from public.push_subs where endpoint = 'https://push.test/1'), 'endpoint follows the last account');
select pg_temp.as_user('00000000-0000-0000-0000-00000000b001');
select public.api_push_unsub('https://push.test/1');
select pg_temp.ok(exists (select 1 from public.push_subs where endpoint = 'https://push.test/1'), 'unsub only removes your own');
select set_config('request.jwt.claims', '', true);

-- Account deleted: its devices go with it.
delete from auth.users where id = '00000000-0000-0000-0000-00000000b002';
select pg_temp.ok(not exists (select 1 from public.push_subs where endpoint = 'https://push.test/1'), 'deleted with the user');

\echo ALL TESTS PASSED
rollback;
