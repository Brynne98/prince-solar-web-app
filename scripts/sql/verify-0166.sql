-- verify-0166: the Notifications list, an alert and its "back" as two rows (SOLAR-431).
-- Local stack only; one transaction, rolled back. Replaces verify-0152's folded-row checks.
-- psql "$LOCAL_DB_URL" -X -q -f scripts/sql/verify-0166.sql   (exit code decides)
\set ON_ERROR_STOP 1
begin;

create function pg_temp.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', what; end if;
  raise notice 'ok: %', what;
end $$;
create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
create function pg_temp.at(k text, ago interval) returns void language sql as $$
  update public.email_queue set created_at = now() - ago where key = k $$;

insert into auth.users (id, email, email_confirmed_at, aud, role)
values ('00000000-0000-0000-0000-00000000c001', 'a1@example.test', now(), 'authenticated', 'authenticated'),
       ('00000000-0000-0000-0000-00000000c002', 'a2@example.test', now(), 'authenticated', 'authenticated');
insert into public.plant_users (plant_id, user_id, plant_name)
values (990201, '00000000-0000-0000-0000-00000000c001', 'Kloof St'),
       (990201, '00000000-0000-0000-0000-00000000c002', 'Mom');
update public.email_queue set pushed_at = now(), push_skip = 'test' where pushed_at is null;

-- An outage 90 days ago that ended; one 40 days ago that ended; one now, still on.
-- A hot battery last week (no back). No readings yesterday, back after 25 min. A welcome.
select private.email_enqueue_plant(990201, 'grid_down', 'gd1', jsonb_build_object('since', extract(epoch from now() - interval '90 days')::bigint, 'chargePct', 70));
select private.email_enqueue_plant(990201, 'grid_back', 'gb1', jsonb_build_object('since', extract(epoch from now() - interval '90 days')::bigint,
  'at', extract(epoch from now() - interval '90 days' + interval '2 hours')::bigint), 'gd1');
select private.email_enqueue_plant(990201, 'grid_down', 'gd2', jsonb_build_object('since', extract(epoch from now() - interval '40 days')::bigint));
select private.email_enqueue_plant(990201, 'grid_back', 'gb2', jsonb_build_object('since', extract(epoch from now() - interval '40 days')::bigint,
  'at', extract(epoch from now() - interval '40 days' + interval '45 minutes')::bigint), 'gd2');
select private.email_enqueue_plant(990201, 'batt_hot', 'bh1', jsonb_build_object('at', extract(epoch from now() - interval '7 days')::bigint, 'tempC', 46));
select private.email_enqueue_plant(990201, 'logger_stale', 'ls1', jsonb_build_object('since', extract(epoch from now() - interval '1 day')::bigint));
select private.email_enqueue_plant(990201, 'logger_back', 'lb1', jsonb_build_object('since', extract(epoch from now() - interval '1 day')::bigint,
  'at', extract(epoch from now() - interval '1 day' + interval '25 minutes')::bigint), 'ls1');
select private.email_enqueue_plant(990201, 'grid_down', 'gd3', jsonb_build_object('since', extract(epoch from now() - interval '1 hour')::bigint));
insert into public.email_queue (user_id, kind, key) values ('00000000-0000-0000-0000-00000000c001', 'welcome', 'welcome:c');
select pg_temp.at('gd1', '90 days'), pg_temp.at('gb1', '90 days' - interval '2 hours'),
       pg_temp.at('gd2', '40 days'), pg_temp.at('gb2', '40 days' - interval '45 minutes'),
       pg_temp.at('bh1', '7 days'), pg_temp.at('ls1', '1 day'), pg_temp.at('lb1', '1 day' - interval '25 minutes'),
       pg_temp.at('gd3', '1 hour');

select pg_temp.as_user('00000000-0000-0000-0000-00000000c001');
do $$
declare r jsonb := public.api_alerts();
        i jsonb := r->'items';
begin
  perform pg_temp.ok(jsonb_array_length(i) = 8, 'one row per alert, backs included: ' || jsonb_array_length(i));
  perform pg_temp.ok(i->0->>'kind' = 'grid_down' and (i->0->>'open')::boolean, 'newest first; the outage now is not back yet');
  perform pg_temp.ok(i->1->>'kind' = 'logger_back' and i->2->>'kind' = 'logger_stale', 'the back is its own row, above its start');
  perform pg_temp.ok(i->1->>'title' <> i->2->>'title' and i->1->>'body' like 'Back after 25 min%', 'the back has its own words: ' || (i->1->>'body'));
  perform pg_temp.ok(not (i->2->>'open')::boolean and not (i->1->>'open')::boolean, 'an ended alert and its back: not open');
  perform pg_temp.ok(i->1->'ids' = jsonb_build_array((i->1->>'id')::bigint), 'each row marks only itself read');
  perform pg_temp.ok(i->1->'endAt' is null, 'no span on a row');
  perform pg_temp.ok(i->7->>'plantName' = 'Kloof St' and i->7->>'title' = 'Grid down', 'oldest last, own plant name, alert words');
  perform pg_temp.ok(not (i @> '[{"kind":"welcome"}]'), 'no welcome');
  perform pg_temp.ok((r->>'unread')::int = 8 and not (r->>'more')::boolean, 'unread counts every row; no more pages');
end $$;

-- filters
select pg_temp.ok(jsonb_array_length(public.api_alerts(now() - interval '30 days')->'items') = 4, 'last 30 days: 4');
select pg_temp.ok(jsonb_array_length(public.api_alerts(now() - interval '1 day' - interval '1 minute')->'items') = 3, 'last day: 3');
select pg_temp.ok(jsonb_array_length(public.api_alerts(p_switch => 'grid')->'items') = 5, 'grid only: 5');
select pg_temp.ok(jsonb_array_length(public.api_alerts(p_switch => 'battery')->'items') = 1, 'battery only: 1');
-- pages of 3
do $$
declare p1 jsonb := public.api_alerts(p_limit => 3); p2 jsonb; p3 jsonb;
begin
  p2 := public.api_alerts(p_before => (p1->'items'->2->>'id')::bigint, p_before_ts => (p1->'items'->2->>'ts')::timestamptz, p_limit => 3);
  p3 := public.api_alerts(p_before => (p2->'items'->2->>'id')::bigint, p_before_ts => (p2->'items'->2->>'ts')::timestamptz, p_limit => 3);
  perform pg_temp.ok((p1->>'more')::boolean and (p2->>'more')::boolean and not (p3->>'more')::boolean
                     and jsonb_array_length(p3->'items') = 2, 'pages of 3: 3, 3, 2');
  perform pg_temp.ok(p2->'items'->0->>'kind' = 'batt_hot', 'page 2 starts after page 1');
end $$;

-- unread only: read the back alone, only it leaves
select public.api_notifications_read(array[(select id from public.email_queue where key = 'lb1' and user_id = '00000000-0000-0000-0000-00000000c001')]);
select pg_temp.ok(jsonb_array_length(public.api_alerts(p_unread => true)->'items') = 7, 'one read: 7 unread rows left');
select pg_temp.ok((public.api_alerts()->'items'->1->>'read')::boolean and not (public.api_alerts()->'items'->2->>'read')::boolean,
                  'the back shows read, its start does not');

-- user 2 sees their own copies; a removed plant leaves
select pg_temp.as_user('00000000-0000-0000-0000-00000000c002');
select pg_temp.ok((public.api_alerts()->>'unread')::int = 8 and public.api_alerts()->'items'->0->>'plantName' = 'Mom', 'user 2: own rows and names');
delete from public.plant_users where plant_id = 990201 and user_id = '00000000-0000-0000-0000-00000000c002';
select pg_temp.ok(jsonb_array_length(public.api_alerts()->'items') = 0, 'removed plant: gone');
select set_config('request.jwt.claims', '', true);
select pg_temp.ok(jsonb_array_length(public.api_alerts()->'items') = 0, 'signed out: nothing');

rollback;
