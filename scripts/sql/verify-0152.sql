-- verify-0152: the full Notifications page reader (SOLAR-327). Local stack only;
-- one transaction, rolled back.
-- psql "$LOCAL_DB_URL" -X -q -f scripts/sql/verify-0152.sql   (exit code decides)
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

-- An outage 3 months ago that ended; one 40 days ago that ended; one now, still on.
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
  perform pg_temp.ok(jsonb_array_length(i) = 5, 'one row per alert, backs folded in: ' || jsonb_array_length(i));
  perform pg_temp.ok(i->0->>'kind' = 'grid_down' and (i->0->>'open')::boolean and i->0->'endAt' = 'null', 'newest first; the outage now is not back yet');
  perform pg_temp.ok(i->1->>'kind' = 'logger_stale' and i->1->>'endTime' is not null and not (i->1->>'open')::boolean
                     and (i->1->>'endAt')::bigint - (i->1->>'at')::bigint = 1500, 'no readings: back 25 min later');
  perform pg_temp.ok(i->2->>'kind' = 'batt_hot' and i->2->'endAt' = 'null', 'hot battery: start only');
  perform pg_temp.ok(jsonb_array_length(i->1->'ids') = 2, 'both rows'' ids to mark read');
  perform pg_temp.ok(i->4->>'plantName' = 'Kloof St' and i->4->>'title' = 'Grid down', 'oldest last, own plant name, alert words');
  perform pg_temp.ok(not (i @> '[{"kind":"welcome"}]') and not (i @> '[{"kind":"grid_back"}]'), 'no welcome, no separate back rows');
  perform pg_temp.ok((r->>'unread')::int = 8 and not (r->>'more')::boolean, 'unread counts every row; no more pages');
end $$;

-- filters
select pg_temp.ok(jsonb_array_length(public.api_alerts(now() - interval '30 days')->'items') = 3, 'last 30 days: 3');
select pg_temp.ok(jsonb_array_length(public.api_alerts(now() - interval '1 day' - interval '1 minute')->'items') = 2, 'last day: 2');
select pg_temp.ok(jsonb_array_length(public.api_alerts(p_switch => 'grid')->'items') = 3, 'grid only: 3');
select pg_temp.ok(jsonb_array_length(public.api_alerts(p_switch => 'battery')->'items') = 1, 'battery only: 1');
-- pages of 2
do $$
declare p1 jsonb := public.api_alerts(p_limit => 2); p2 jsonb; p3 jsonb;
begin
  p2 := public.api_alerts(p_before => (p1->'items'->1->>'id')::bigint, p_before_ts => (p1->'items'->1->>'ts')::timestamptz, p_limit => 2);
  p3 := public.api_alerts(p_before => (p2->'items'->1->>'id')::bigint, p_before_ts => (p2->'items'->1->>'ts')::timestamptz, p_limit => 2);
  perform pg_temp.ok((p1->>'more')::boolean and (p2->>'more')::boolean and not (p3->>'more')::boolean
                     and jsonb_array_length(p3->'items') = 1, 'pages of 2: 2, 2, 1');
  perform pg_temp.ok(p2->'items'->0->>'kind' = 'batt_hot', 'page 2 starts after page 1');
end $$;

-- unread only: read the "down" of no readings, it stays (its back is unread); read both, it goes
select public.api_notifications_read(array[(select id from public.email_queue where key = 'ls1' and user_id = '00000000-0000-0000-0000-00000000c001')]);
select pg_temp.ok(jsonb_array_length(public.api_alerts(p_unread => true)->'items') = 5, 'half read: still unread');
select public.api_notifications_read(array(select (jsonb_array_elements(public.api_alerts(p_switch => 'readings')->'items'->0->'ids'))::bigint));
select pg_temp.ok(jsonb_array_length(public.api_alerts(p_unread => true)->'items') = 4, 'both read: out of unread only');
select pg_temp.ok((public.api_alerts()->'items'->1->>'read')::boolean, 'shown as read');

-- an earlier outage with no back, ended by a later one: not "not back yet"
select private.email_enqueue_plant(990201, 'grid_down', 'gd0', jsonb_build_object('since', extract(epoch from now() - interval '100 days')::bigint));
select pg_temp.at('gd0', '100 days');
select pg_temp.ok(not (public.api_alerts(p_switch => 'grid')->'items'->-1->>'open')::boolean, 'a later outage ends an unpaired one');

-- user 2 sees their own copies, not user 1's read state; a removed plant leaves
select pg_temp.as_user('00000000-0000-0000-0000-00000000c002');
select pg_temp.ok((public.api_alerts()->>'unread')::int = 9 and public.api_alerts()->'items'->0->>'plantName' = 'Mom', 'user 2: own rows and names');
delete from public.plant_users where plant_id = 990201 and user_id = '00000000-0000-0000-0000-00000000c002';
select pg_temp.ok(jsonb_array_length(public.api_alerts()->'items') = 0, 'removed plant: gone');
select set_config('request.jwt.claims', '', true);
select pg_temp.ok(jsonb_array_length(public.api_alerts()->'items') = 0, 'signed out: nothing');

rollback;
