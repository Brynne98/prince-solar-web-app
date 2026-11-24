-- SOLAR-645 step 3 (0261): the message outbox, pop-ups first.
-- LOCAL database only, with every migration applied. One transaction, rolled back:
--   psql "$DB" -v ON_ERROR_STOP=1 -f scripts/sql/msg-outbox-tests.sql
-- Exit 0: every check passed. A failed check raises, so psql exits 3.
-- now() is fixed in a transaction: "later" is made by moving times back.

begin;
set client_min_messages = notice;
-- the routes as migrated, for S3
create temp table t_routes as select kind, channel, route, lane from msg.kinds;

create temp table t_results (n serial, label text, pass boolean, detail text);
create function pg_temp.ok(p_label text, p_cond boolean, p_detail text default null)
returns void language sql as $$
  insert into t_results (label, pass, detail) values (p_label, coalesce(p_cond, false), p_detail)
$$;
create function pg_temp.ep(p timestamptz) returns bigint language sql immutable as $$ select extract(epoch from p)::bigint $$;

-- an owner with chosen plants and a stored login (as alert-queue-tests)
create function pg_temp.owner(p_name text, p_plants bigint[], p_at timestamptz default now() - interval '2 days')
returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); a uuid; l uuid := gen_random_uuid(); i int;
begin
  insert into auth.users (id, email, created_at) values (u, p_name || '@msg.test', p_at);
  insert into billing.accounts (user_id, market, created_at) values (u, 'ZA', p_at) returning id into a;
  insert into public.plant_config (plant_id, timezone) select x, 'Africa/Johannesburg' from unnest(p_plants) x
  on conflict (plant_id) do nothing;
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, linked_at, last_ok_at, last_try, last_try_at)
  values (l, u, p_name, 'active', p_at, now(), 'ok', now());
  perform billing.link_login(a, 'sunsynk', p_name, null,
    (select jsonb_agg(jsonb_build_object('id', x, 'name', 'Plant ' || x)) from unnest(p_plants) x), p_at, 'owner', l);
  for i in 1 .. cardinality(p_plants) loop
    insert into public.plant_users (plant_id, user_id, account_id, plant_name, linked_at)
    values (p_plants[i], u, l, 'Plant ' || p_plants[i], p_at + (i - 1) * interval '1 hour');
  end loop;
  perform billing.set_chosen_plants(a, p_plants, p_at);
  return u;
end $$;
create function pg_temp.acc(p_user uuid) returns uuid language sql as $$ select id from billing.accounts where user_id = p_user $$;
create function pg_temp.dev(p_user uuid, p_tag text) returns bigint language sql as $$
  insert into public.push_subs (user_id, platform, endpoint, p256dh, auth)
  values (p_user, 'web', 'https://fcm.googleapis.com/fcm/send/msg-test-' || p_tag, 'k', 'a') returning id
$$;
create function pg_temp.ev(p_user uuid, p_plant bigint, p_kind text, p_key text, p_pair text default null,
                           p_at timestamptz default now())
returns bigint language sql as $$
  insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority, created_at)
  values (p_user, p_plant, p_kind, p_key, p_pair, jsonb_build_object('since', pg_temp.ep(now())), 0, p_at) returning id
$$;
create function pg_temp.ob(p_event bigint) returns msg.outbox language sql as $$
  select * from msg.outbox where dedupe_key = p_event || ':push'
$$;

-- each take's rows, kept for the done calls
create temp table t_take as select * from public.msg_push_take(0) limit 0;
create function pg_temp.take() returns int language plpgsql as $$
declare n int;
begin
  truncate t_take;
  insert into t_take select * from public.msg_push_take(1000);
  get diagnostics n = row_count;
  return n;
end $$;
-- the sends of one event in the last take, as device ids
create function pg_temp.taken(p_event bigint) returns bigint[] language sql as $$
  select coalesce(array_agg(s.sub_id order by s.sub_id), '{}') from t_take t join msg.push_sends s on s.id = t.id where t.event_id = p_event
$$;
create function pg_temp.done(p_event bigint, p_code int, p_retry int default null) returns void language sql as $$
  select public.msg_push_done(t.claim, jsonb_agg(jsonb_build_object('id', t.id, 'code', p_code, 'retry_s', p_retry)))
    from t_take t where t.event_id = p_event group by t.claim
$$;
create function pg_temp.send(p_event bigint, p_sub bigint) returns msg.push_sends language sql as $$
  select s.* from msg.push_sends s join msg.outbox o on o.id = s.outbox_id
   where o.dedupe_key = p_event || ':push' and s.sub_id is not distinct from p_sub
$$;

-- ---------------------------------------------------------------------------
-- R: route at insert
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('r1', '{990065901}'); q bigint; s bigint; w bigint; o msg.outbox; got bigint[];
begin
  q := pg_temp.ev(u, 990065901, 'grid_down', 'r1:down');
  o := pg_temp.ob(q);
  perform pg_temp.ok('R1 alert: pop-up and email marked for the outbox',
    (select (push_skip, status) = ('outbox', 'outbox') and pushed_at is not null from public.email_queue where id = q),
    (select format('%s %s', push_skip, status) from public.email_queue where id = q));
  perform pg_temp.ok('R1 ... a push row, urgent, 1 h expiry, address captured; and an email row',
    o.channel = 'push' and o.lane = 'urgent' and o.status = 'queued' and o.expires_at = o.not_before + interval '1 hour'
    and o.to_email = 'r1@msg.test'
    and exists (select 1 from msg.outbox where dedupe_key = q || ':email' and lane = 'urgent')
    and (select count(*) from msg.outbox where event_id = q) = 2, row_to_json(o)::text);

  insert into public.email_queue (user_id, plant_id, kind, key, priority, status, last_error)
  values (u, 990065901, 'needs_relink', 'r1:copy', 0, 'skipped', 'one email per login') returning id into s;
  perform pg_temp.ok('R2 reconnect copy (skipped): no outbox row, pop-up marked "one per login"',
    pg_temp.ob(s) is null and (select push_skip from public.email_queue where id = s) = 'one per login');

  insert into public.email_queue (user_id, kind, key, priority) values (u, 'welcome', 'r1:welcome', 1) returning id into w;
  perform pg_temp.ok('R3 not an alert: no pop-up row, an email row',
    pg_temp.ob(w) is null and (select pushed_at from public.email_queue where id = w) is null
    and exists (select 1 from msg.outbox where dedupe_key = w || ':email'));

  -- a row the seat trigger drops is never routed
  q := pg_temp.ev(u, 990065999, 'grid_down', 'r1:other-plant');
  perform pg_temp.ok('R5 dropped by the seat trigger: no row, no outbox row', q is null);
end $$;

-- ---------------------------------------------------------------------------
-- T, D: take and done, per device
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('t1', '{990065902}'); d1 bigint; d2 bigint; q bigint; o msg.outbox; n int; s msg.push_sends;
begin
  d1 := pg_temp.dev(u, 't1a'); d2 := pg_temp.dev(u, 't1b');
  q := pg_temp.ev(u, 990065902, 'grid_down', 't1:down');
  n := pg_temp.take();
  perform pg_temp.ok('T1 take: one send per device, with the facts (words: alerts_test, push_test) and a claim',
    pg_temp.taken(q) = array[d1, d2]
    and (select bool_and(data is not null and tz is not null and claim is not null and endpoint like 'https://fcm%') from t_take where event_id = q),
    pg_temp.taken(q)::text);
  o := pg_temp.ob(q);
  perform pg_temp.ok('T1 ... outbox row leased to its expiry', o.status = 'queued' and o.claimed_until = o.expires_at);
  n := pg_temp.take();
  perform pg_temp.ok('T2 a leased send is not handed out again', pg_temp.taken(q) = '{}');
  perform public.msg_push_done(gen_random_uuid(), (select jsonb_agg(jsonb_build_object('id', id, 'code', 201)) from t_take));
  perform pg_temp.ok('T3 done under another claim changes nothing', (pg_temp.send(q, d1)).status = 'sending');
end $$;

do $$
declare u uuid := pg_temp.owner('d1', '{990065903}'); d1 bigint; d2 bigint; q bigint; s msg.push_sends; o msg.outbox; n int; j jsonb;
begin
  d1 := pg_temp.dev(u, 'd1a'); d2 := pg_temp.dev(u, 'd1b');
  q := pg_temp.ev(u, 990065903, 'grid_down', 'd1:down');
  n := pg_temp.take();
  perform public.msg_push_done((select claim from t_take where event_id = q limit 1), jsonb_build_array(
    jsonb_build_object('id', (pg_temp.send(q, d1)).id, 'code', 201),
    jsonb_build_object('id', (pg_temp.send(q, d2)).id, 'code', 429, 'retry_s', 7)));
  s := pg_temp.send(q, d1);
  perform pg_temp.ok('D1 201: sent, device marked ok',
    s.status = 'sent' and s.sent_at is not null and (select last_ok_at from public.push_subs where id = d1) is not null);
  s := pg_temp.send(q, d2);
  perform pg_temp.ok('D2 429: back on the queue after Retry-After, counted',
    s.status = 'queued' and s.not_before = now() + interval '7 seconds' and s.n429 = 1 and s.last_code = 429, row_to_json(s)::text);
  perform pg_temp.ok('D2 ... outbox row still open while a device is', (pg_temp.ob(q)).status = 'queued');
  j := (select x from jsonb_array_elements(public.job_check_msg()) x where x->>'channel' = 'push' and x->>'lane' = 'urgent');
  perform pg_temp.ok('M1 job_check_msg: push lane, 429 counted, row queued; a send waiting on Retry-After is not due',
    (j->>'n429')::int >= 1 and (j->>'queued')::int >= 1
    and (j->>'oldest' is null or (j->>'oldest')::timestamptz > now() - interval '1 minute'), j::text);
  n := pg_temp.take();
  perform pg_temp.ok('D2 ... not taken before Retry-After', pg_temp.taken(q) = '{}');
  update msg.push_sends set not_before = now() where id = s.id;
  n := pg_temp.take();
  perform pg_temp.ok('D2 ... taken after it, second try', pg_temp.taken(q) = array[d2] and (pg_temp.send(q, d2)).tries = 2);
  perform pg_temp.done(q, 503);
  s := pg_temp.send(q, d2);
  perform pg_temp.ok('D3 5xx without Retry-After: 30 s doubling (try 2 = 60 s)',
    s.status = 'queued' and s.not_before = now() + interval '60 seconds', row_to_json(s)::text);
  update msg.push_sends set not_before = now() where id = s.id;
  n := pg_temp.take();
  perform pg_temp.done(q, 0);
  perform pg_temp.ok('D4 no answer (0): tried again', (pg_temp.send(q, d2)).status = 'queued');
  update msg.push_sends set not_before = now() where id = s.id;
  n := pg_temp.take();
  perform pg_temp.done(q, 201);
  o := pg_temp.ob(q);
  perform pg_temp.ok('D5 all devices done: outbox row sent, lease cleared',
    o.status = 'sent' and o.claimed_until is null and o.done_at is not null, row_to_json(o)::text);
end $$;

do $$
declare u uuid := pg_temp.owner('d6', '{990065904}'); d1 bigint; d2 bigint; q bigint; o msg.outbox; n int;
begin
  d1 := pg_temp.dev(u, 'd6a'); d2 := pg_temp.dev(u, 'd6b');
  q := pg_temp.ev(u, 990065904, 'grid_down', 'd6:down');
  n := pg_temp.take();
  perform public.msg_push_done((select claim from t_take where event_id = q limit 1), jsonb_build_array(
    jsonb_build_object('id', (pg_temp.send(q, d1)).id, 'code', 410),
    jsonb_build_object('id', (pg_temp.send(q, d2)).id, 'code', 400, 'error', 'bad request')));
  perform pg_temp.ok('D6 410: device removed, send "gone"',
    not exists (select 1 from public.push_subs where id = d1) and (pg_temp.send(q, null)).status = 'gone');
  perform pg_temp.ok('D7 400: failed, not tried again', (pg_temp.send(q, d2)).status = 'failed'
    and (pg_temp.send(q, d2)).last_error = 'bad request');
  o := pg_temp.ob(q);
  perform pg_temp.ok('D7 ... no device took it: outbox row failed', o.status = 'failed', row_to_json(o)::text);
end $$;

do $$
declare u uuid := pg_temp.owner('d8', '{990065905}'); d1 bigint; q bigint; n int; s msg.push_sends;
begin
  d1 := pg_temp.dev(u, 'd8a');
  q := pg_temp.ev(u, 990065905, 'grid_down', 'd8:down', null, now() - interval '59 minutes');
  n := pg_temp.take();
  perform pg_temp.done(q, 429, 120);
  s := pg_temp.send(q, d1);
  perform pg_temp.ok('D8 a retry that would land past the hour: failed "too old"',
    s.status = 'failed' and s.last_error = 'too old' and (pg_temp.ob(q)).status = 'failed'
    and (pg_temp.ob(q)).last_error = 'too old', row_to_json(s)::text);
  perform pg_temp.ok('M2 job_check_msg counts it as expired',
    ((select x from jsonb_array_elements(public.job_check_msg()) x where x->>'lane' = 'urgent' and x->>'channel' = 'push')->>'expired')::int >= 1);
end $$;

-- lost reply: the lease runs out, the send goes again under a new claim; the old claim's late
-- answer is ignored
do $$
declare u uuid := pg_temp.owner('l1', '{990065906}'); d1 bigint; q bigint; n int; c1 uuid; sid bigint;
begin
  d1 := pg_temp.dev(u, 'l1a');
  q := pg_temp.ev(u, 990065906, 'grid_down', 'l1:down');
  n := pg_temp.take();
  c1 := (select claim from t_take where event_id = q); sid := (pg_temp.send(q, d1)).id;
  update msg.push_sends set claimed_until = now() - interval '1 second' where id = sid;
  n := pg_temp.take();
  perform pg_temp.ok('L1 lost reply: lease ran out, sent again under a new claim',
    pg_temp.taken(q) = array[d1] and (select claim from t_take where event_id = q) <> c1 and (pg_temp.send(q, d1)).tries = 2);
  perform public.msg_push_done(c1, jsonb_build_array(jsonb_build_object('id', sid, 'code', 201)));
  perform pg_temp.ok('L1 ... the late answer to the old claim is ignored', (pg_temp.send(q, d1)).status = 'sending');
  perform pg_temp.done(q, 201);
  perform pg_temp.ok('L1 ... the new claim closes it', (pg_temp.ob(q)).status = 'sent');
end $$;

-- a device removed while its send waits
do $$
declare u uuid := pg_temp.owner('l2', '{990065907}'); d1 bigint; q bigint; n int;
begin
  d1 := pg_temp.dev(u, 'l2a');
  q := pg_temp.ev(u, 990065907, 'grid_down', 'l2:down');
  n := pg_temp.take();
  perform pg_temp.done(q, 503, 5);
  delete from public.push_subs where id = d1;
  n := pg_temp.take();
  perform pg_temp.ok('L2 device removed while waiting: send "gone", outbox row failed',
    (pg_temp.send(q, null)).status = 'gone' and (pg_temp.ob(q)).status = 'failed', (pg_temp.ob(q)).status);
end $$;

-- ---------------------------------------------------------------------------
-- G: the guard at send time
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('g1', '{990065911,990065912,990065913}'); a uuid; q1 bigint; q2 bigint; q3 bigint; q4 bigint; q5 bigint; q6 bigint; n int;
begin
  a := pg_temp.acc(u);
  perform pg_temp.dev(u, 'g1a');
  q1 := pg_temp.ev(u, 990065911, 'grid_down', 'g1:old', null, now() - interval '61 minutes');
  q2 := pg_temp.ev(u, 990065912, 'grid_down', 'g1:removed');
  q3 := pg_temp.ev(u, 990065913, 'grid_down', 'g1:unchosen');
  q4 := pg_temp.ev(u, 990065911, 'batt_hot', 'g1:switch');
  q5 := pg_temp.ev(u, 990065911, 'needs_relink', 'g1:relink');
  q6 := pg_temp.ev(u, 990065911, 'grid_back', 'g1:back', 'g1:no-such-down');
  -- after queueing: plant removed, plant switched out, battery switch off
  delete from public.plant_users where user_id = u and plant_id = 990065912;
  perform billing.set_chosen_plants(a, '{990065911,990065912}', now());
  insert into public.push_prefs (user_id, battery) values (u, false);
  n := pg_temp.take();
  perform pg_temp.ok('G1 over an hour old: dropped "too old"', (pg_temp.ob(q1)).drop_reason = 'too old', (pg_temp.ob(q1)).drop_reason);
  perform pg_temp.ok('G2 plant removed', (pg_temp.ob(q2)).drop_reason = 'plant removed', (pg_temp.ob(q2)).drop_reason);
  perform pg_temp.ok('G3 plant not chosen', (pg_temp.ob(q3)).drop_reason = 'plant not chosen', (pg_temp.ob(q3)).drop_reason);
  perform pg_temp.ok('G4 switch off', (pg_temp.ob(q4)).drop_reason = 'switched off', (pg_temp.ob(q4)).drop_reason);
  perform pg_temp.ok('G5 reconnect has no switch: sent', pg_temp.taken(q5) <> '{}' and (pg_temp.ob(q5)).status = 'queued');
  perform pg_temp.ok('G6 a "back" with no "down" row: dropped', (pg_temp.ob(q6)).drop_reason = 'down had no pop-up',
    (pg_temp.ob(q6)).drop_reason);
  perform pg_temp.ok('G1 ... dropped rows are done', (pg_temp.ob(q1)).status = 'dropped' and (pg_temp.ob(q1)).done_at is not null);
end $$;

do $$
declare u uuid := pg_temp.owner('g7', '{990065914}'); q bigint; n int;
begin
  q := pg_temp.ev(u, 990065914, 'grid_down', 'g7:nodev');
  n := pg_temp.take();
  perform pg_temp.ok('G7 no device: dropped "no device"', (pg_temp.ob(q)).drop_reason = 'no device', (pg_temp.ob(q)).drop_reason);
end $$;

-- plant not live: its login needs reconnecting. Reconnect itself still goes: it is queued just
-- before the login is marked broken, so its plant is never read when it is sent.
do $$
declare u uuid := pg_temp.owner('g8', '{990065915}'); q bigint; r bigint; n int;
begin
  perform pg_temp.dev(u, 'g8a');
  q := pg_temp.ev(u, 990065915, 'grid_down', 'g8:down');
  r := pg_temp.ev(u, 990065915, 'needs_relink', 'g8:relink');
  update billing.logins set status = 'needs_reconnect' where account = pg_temp.acc(u);
  n := pg_temp.take();
  perform pg_temp.ok('G8 plant not read any more: dropped "plant not live"',
    (pg_temp.ob(q)).drop_reason = 'plant not live', (pg_temp.ob(q)).drop_reason);
  perform pg_temp.ok('G9 reconnect on that plant still goes', pg_temp.taken(r) <> '{}', (pg_temp.ob(r)).drop_reason);
end $$;

-- ---------------------------------------------------------------------------
-- P: down/back pairs
-- ---------------------------------------------------------------------------
-- both on the outbox; a "back" goes only to devices that took the "down"
do $$
declare u uuid := pg_temp.owner('p1', '{990065921}'); da bigint; db bigint; dc bigint; down bigint; back bigint; n int;
begin
  da := pg_temp.dev(u, 'p1a'); db := pg_temp.dev(u, 'p1b');
  down := pg_temp.ev(u, 990065921, 'grid_down', 'p1:down');
  back := pg_temp.ev(u, 990065921, 'grid_back', 'p1:back', 'p1:down');
  n := pg_temp.take();
  perform pg_temp.ok('P1 "back" waits while its "down" is open',
    pg_temp.taken(down) = array[da, db] and pg_temp.taken(back) = '{}' and (pg_temp.ob(back)).status = 'queued'
    and (pg_temp.ob(back)).claimed_until is null);
  perform public.msg_push_done((select claim from t_take where event_id = down limit 1), jsonb_build_array(
    jsonb_build_object('id', (pg_temp.send(down, da)).id, 'code', 201),
    jsonb_build_object('id', (pg_temp.send(down, db)).id, 'code', 400)));
  dc := pg_temp.dev(u, 'p1c');                                  -- a device added after the "down"
  n := pg_temp.take();
  perform pg_temp.ok('P2 "back" only to the device that took the "down"', pg_temp.taken(back) = array[da],
    pg_temp.taken(back)::text);
end $$;

-- "down" dropped: its "back" is dropped; "down" never dropped because of its "back"
do $$
declare u uuid := pg_temp.owner('p3', '{990065922}'); down bigint; back bigint; n int;
begin
  perform pg_temp.dev(u, 'p3a');
  insert into public.push_prefs (user_id, grid) values (u, false);
  down := pg_temp.ev(u, 990065922, 'grid_down', 'p3:down');
  n := pg_temp.take();
  update public.push_prefs set grid = true where user_id = u;
  back := pg_temp.ev(u, 990065922, 'grid_back', 'p3:back', 'p3:down');
  n := pg_temp.take();
  perform pg_temp.ok('P3 "down" dropped (switch off then): "back" dropped "down had no pop-up"',
    (pg_temp.ob(down)).drop_reason = 'switched off' and (pg_temp.ob(back)).drop_reason = 'down had no pop-up');
end $$;

do $$
declare u uuid := pg_temp.owner('p4', '{990065923}'); down bigint; back bigint; n int;
begin
  perform pg_temp.dev(u, 'p4a');
  down := pg_temp.ev(u, 990065923, 'grid_down', 'p4:down');
  n := pg_temp.take();
  perform pg_temp.done(down, 400);
  back := pg_temp.ev(u, 990065923, 'grid_back', 'p4:back', 'p4:down');
  n := pg_temp.take();
  perform pg_temp.ok('P4 "down" failed on every device: "back" dropped', (pg_temp.ob(back)).drop_reason = 'down had no pop-up');
end $$;

-- ---------------------------------------------------------------------------
-- X: no old path (0265)
-- ---------------------------------------------------------------------------
do $$
declare refused boolean := false;
begin
  begin
    update msg.kinds set route = 'old' where kind = 'grid_down' and channel = 'push';
  exception when check_violation then refused := true;
  end;
  perform pg_temp.ok('X1 a kind can no longer go back to the old path', refused);
  perform pg_temp.ok('X2 the old path functions are gone',
    not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname in ('public', 'private', 'billing')
                   and p.proname in ('email_claim', 'email_done', 'push_claim', 'push_done', 'alert_text', 'old_billing_email',
                                     'api_alerts_due', 'api_alerts_due_raw')));
end $$;

-- 0267: a "down" pushed on the old path still pairs; one never handled no longer makes a "back" wait
do $$
declare u uuid := pg_temp.owner('x3', '{990065935}'); b1 bigint; b2 bigint; n int;
begin
  perform pg_temp.dev(u, 'x3a');
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority, status, pushed_at)
  values (u, 990065935, 'grid_down', 'x3:old', '{}', 0, 'sent', now() - interval '2 hours'),
         (u, 990065935, 'batt_hot', 'x3:never', '{}', 0, 'sent', null);
  update public.email_queue set pushed_at = null, push_skip = null where user_id = u and key = 'x3:never';
  b1 := pg_temp.ev(u, 990065935, 'grid_back', 'x3:b1', 'x3:old');
  b2 := pg_temp.ev(u, 990065935, 'batt_hot_back', 'x3:b2', 'x3:never');
  n := pg_temp.take();
  perform pg_temp.ok('X3 "back" whose "down" was pushed on the old path: goes', cardinality(pg_temp.taken(b1)) = 1);
  perform pg_temp.ok('X3 ... whose "down" was never handled: dropped, not left waiting',
    (pg_temp.ob(b2)).drop_reason = 'down had no pop-up', (pg_temp.ob(b2)).drop_reason);
end $$;

-- ---------------------------------------------------------------------------
-- V: review fixes
-- ---------------------------------------------------------------------------
-- Retry-After 0 still waits 5 s; a leased row retrying is not "stuck" for job-check
do $$
declare u uuid := pg_temp.owner('v1', '{990065941}'); d1 bigint; q bigint; n int; j jsonb;
begin
  d1 := pg_temp.dev(u, 'v1a');
  q := pg_temp.ev(u, 990065941, 'grid_down', 'v1:down', null, now() - interval '20 minutes');
  update msg.outbox set not_before = now() - interval '20 minutes' where dedupe_key = q || ':push';
  n := pg_temp.take();
  perform pg_temp.done(q, 429, 0);
  perform pg_temp.ok('V1 Retry-After 0: waits 5 s, not a loop', (pg_temp.send(q, d1)).not_before = now() + interval '5 seconds',
    (pg_temp.send(q, d1)).not_before::text);
  j := (select x from jsonb_array_elements(public.job_check_msg()) x where x->>'lane' = 'urgent' and x->>'channel' = 'push');
  perform pg_temp.ok('V2 job_check_msg: a 20-min-old row retrying a device is not the oldest due',
    j->>'oldest' is null or (j->>'oldest')::timestamptz > now() - interval '20 minutes', j::text);
  update msg.push_sends set not_before = now() - interval '10 minutes' where id = (pg_temp.send(q, d1)).id;
  j := (select x from jsonb_array_elements(public.job_check_msg()) x where x->>'lane' = 'urgent' and x->>'channel' = 'push');
  perform pg_temp.ok('V2 ... but a device send due 10 min and not taken is',
    (j->>'oldest')::timestamptz <= now() - interval '10 minutes', j::text);
  update msg.push_sends set status = 'failed' where id = (pg_temp.send(q, d1)).id;
  perform msg.push_settle(array[(pg_temp.ob(q)).id]);
end $$;

-- waiting "back" rows never fill the take: with room for one row, the new "down" still goes
do $$
declare u uuid := pg_temp.owner('v3', '{990065942,990065943}'); down bigint; back bigint; other bigint; n int;
begin
  perform pg_temp.dev(u, 'v3a');
  down := pg_temp.ev(u, 990065942, 'grid_down', 'v3:down');
  n := pg_temp.take();                                                    -- down leased, its device send open
  back := pg_temp.ev(u, 990065942, 'grid_back', 'v3:back', 'v3:down');   -- waits
  other := pg_temp.ev(u, 990065943, 'grid_down', 'v3:other');
  update msg.outbox set not_before = now() - interval '1 minute' where dedupe_key = back || ':push';
  perform count(*) from public.msg_push_take(1);
  perform pg_temp.ok('V3 a waiting "back" first in line does not block the next row',
    (pg_temp.ob(other)).claimed_until is not null and (pg_temp.ob(back)).claimed_until is null,
    format('other %s back %s', (pg_temp.ob(other)).claimed_until, (pg_temp.ob(back)).claimed_until));
end $$;

-- reconnect for a login with no plant: no plant to test, it goes
do $$
declare u uuid := pg_temp.owner('v4', '{990065944}'); q bigint; n int;
begin
  perform pg_temp.dev(u, 'v4a');
  q := pg_temp.ev(u, null, 'needs_relink', 'v4:relink');
  n := pg_temp.take();
  perform pg_temp.ok('V4 reconnect with no plant: sent, not "plant removed"', pg_temp.taken(q) <> '{}',
    (pg_temp.ob(q)).drop_reason);
end $$;

-- a failed row says "too old" when any device ran out of time, so it counts as expired
do $$
declare u uuid := pg_temp.owner('v5', '{990065945}'); d1 bigint; d2 bigint; q bigint; n int;
begin
  d1 := pg_temp.dev(u, 'v5a'); d2 := pg_temp.dev(u, 'v5b');
  q := pg_temp.ev(u, 990065945, 'grid_down', 'v5:down', null, now() - interval '59 minutes');
  n := pg_temp.take();
  perform public.msg_push_done((select claim from t_take where event_id = q limit 1), jsonb_build_array(
    jsonb_build_object('id', (pg_temp.send(q, d1)).id, 'code', 503, 'retry_s', 120),
    jsonb_build_object('id', (pg_temp.send(q, d2)).id, 'code', 410)));
  perform pg_temp.ok('V5 one device "too old", one removed: row failed "too old"',
    (pg_temp.ob(q)).status = 'failed' and (pg_temp.ob(q)).last_error = 'too old', (pg_temp.ob(q)).last_error);
end $$;

-- ---------------------------------------------------------------------------
-- S: who may call it
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.ok('S1 take, done, job_check_msg: service role only',
    has_function_privilege('service_role', 'public.msg_push_take(int)', 'execute')
    and has_function_privilege('service_role', 'public.msg_push_done(uuid, jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.job_check_msg()', 'execute')
    and not has_function_privilege('anon', 'public.msg_push_take(int)', 'execute')
    and not has_function_privilege('authenticated', 'public.msg_push_done(uuid, jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'public.job_check_msg()', 'execute'));
  perform pg_temp.ok('S2 msg schema closed to the API roles',
    not has_schema_privilege('anon', 'msg', 'usage') and not has_schema_privilege('authenticated', 'msg', 'usage'));
  perform pg_temp.ok('S3 every alert kind routes pop-ups and emails (0262) to the outbox; share_down/back emails too (0265)',
    (select count(*) from t_routes where channel = 'push' and route = 'outbox') = 14
    and (select count(*) from t_routes where channel = 'email' and route = 'outbox' and lane = 'urgent') = 16
    and (select count(*) from t_routes where route <> 'outbox') = 0);
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r record; bad int := 0;
begin
  for r in select * from t_results order by n loop
    if r.pass then raise notice 'ok    %', r.label;
    else raise notice 'FAIL  %  (%)', r.label, r.detail; bad := bad + 1; end if;
  end loop;
  if bad > 0 then raise exception '% of % checks failed', bad, (select count(*) from t_results); end if;
  raise notice 'all % checks passed', (select count(*) from t_results);
end $$;
rollback;
