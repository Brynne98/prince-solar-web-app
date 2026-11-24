-- SOLAR-645 step 4 (0262): alert emails through the message outbox.
-- LOCAL database only, with every migration applied. One transaction, rolled back:
--   psql "$DB" -v ON_ERROR_STOP=1 -f scripts/sql/msg-outbox-email-tests.sql
-- Exit 0: every check passed. A failed check raises, so psql exits 3.
-- now() is fixed in a transaction: "later" is made by moving times back.

begin;
set client_min_messages = notice;

create temp table t_results (n serial, label text, pass boolean, detail text);
create function pg_temp.ok(p_label text, p_cond boolean, p_detail text default null)
returns void language sql as $$
  insert into t_results (label, pass, detail) values (p_label, coalesce(p_cond, false), p_detail)
$$;
create function pg_temp.ep(p timestamptz) returns bigint language sql immutable as $$ select extract(epoch from p)::bigint $$;

-- an owner with chosen plants and a stored login (as msg-outbox-tests)
create function pg_temp.owner(p_name text, p_plants bigint[], p_at timestamptz default now() - interval '2 days')
returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); a uuid; l uuid := gen_random_uuid(); i int;
begin
  insert into auth.users (id, email, created_at) values (u, p_name || '@msge.test', p_at);
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
create function pg_temp.ev(p_user uuid, p_plant bigint, p_kind text, p_key text, p_pair text default null,
                           p_at timestamptz default now())
returns bigint language sql as $$
  insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority, created_at, due_at)
  values (p_user, p_plant, p_kind, p_key, p_pair,
          jsonb_build_object('since', pg_temp.ep(p_at - interval '5 minutes'), 'at', pg_temp.ep(p_at)), 0, p_at, p_at)
  returning id
$$;
create function pg_temp.ob(p_event bigint) returns msg.outbox language sql as $$
  select * from msg.outbox where dedupe_key = p_event || ':email'
$$;

-- each take's rows, kept for the done calls
create temp table t_take as select * from public.msg_email_take(0) limit 0;
create function pg_temp.take(p_limit int default 1000) returns int language plpgsql as $$
declare n int;
begin
  truncate t_take;
  insert into t_take select * from public.msg_email_take(p_limit);
  get diagnostics n = row_count;
  return n;
end $$;
create function pg_temp.taken(p_event bigint) returns boolean language sql as $$
  select exists (select 1 from t_take where event_id = p_event)
$$;
create function pg_temp.done(p_event bigint, p_res jsonb) returns void language sql as $$
  select public.msg_email_done(t.claim, jsonb_build_array(jsonb_build_object('id', t.id) || p_res))
    from t_take t where t.event_id = p_event
$$;
-- the old path, as notify: claim (urgent lane) and mark each claimed row sent
create function pg_temp.old_send(p_user uuid) returns bigint[] language plpgsql as $$
declare got bigint[];
begin
  got := array(select id from public.email_claim(100, false, 'urgent') where user_id = p_user order by id);
  perform public.email_done((select jsonb_agg(jsonb_build_object('id', x, 'status', 'sent')) from unnest(got) x));
  return got;
end $$;

-- ---------------------------------------------------------------------------
-- R: route at insert
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('r1', '{990066901}'); q bigint; o msg.outbox; w bigint;
begin
  q := pg_temp.ev(u, 990066901, 'grid_down', 'r1:down');
  o := pg_temp.ob(q);
  perform pg_temp.ok('R1 alert email: event "outbox", one email row, urgent, 1 h expiry, address captured',
    (select status from public.email_queue where id = q) = 'outbox'
    and o.channel = 'email' and o.lane = 'urgent' and o.status = 'queued' and o.expires_at = now() + interval '1 hour'
    and o.to_email = 'r1@msge.test', row_to_json(o)::text);
  perform pg_temp.ok('R1 ... email_claim never takes it', q not in (select id from public.email_claim(100, true)));
  insert into public.email_queue (user_id, kind, key, priority) values (u, 'welcome', 'r1:welcome', 1) returning id into w;
  perform pg_temp.ok('R2 not an alert: stays on the old path',
    (select status from public.email_queue where id = w) = 'queued' and pg_temp.ob(w) is null);
end $$;

-- ---------------------------------------------------------------------------
-- T, D: take and done
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('t1', '{990066902}'); q bigint; o msg.outbox; t record; n int;
begin
  q := pg_temp.ev(u, 990066902, 'grid_down', 't1:down');
  n := pg_temp.take();
  select * into t from t_take where event_id = q;
  perform pg_temp.ok('T1 take: the event row''s fields, a claim, first try',
    t.claim is not null and t.tries = 1 and t.to_email = 't1@msge.test' and t.plant_name = 'Plant 990066902'
    and t.tz = 'Africa/Johannesburg' and t.kind = 'grid_down' and t.key = 't1:down' and t.data ? 'since', row_to_json(t)::text);
  o := pg_temp.ob(q);
  perform pg_temp.ok('T1 ... leased 2 minutes under that claim', o.claim = t.claim and o.claimed_until = now() + interval '2 minutes'
    and o.tries = 1 and o.status = 'queued');
  n := pg_temp.take();
  perform pg_temp.ok('T2 a leased row is not handed out again', not pg_temp.taken(q));
  perform public.msg_email_done(gen_random_uuid(), jsonb_build_array(jsonb_build_object('id', o.id, 'code', 200)));
  perform pg_temp.ok('T3 done under another claim changes nothing', (pg_temp.ob(q)).status = 'queued' and (pg_temp.ob(q)).claim = t.claim);
  perform public.msg_email_done(t.claim, jsonb_build_array(jsonb_build_object('id', o.id, 'code', 200)));
  o := pg_temp.ob(q);
  perform pg_temp.ok('D1 200: sent, lease cleared, done', o.status = 'sent' and o.claim is null and o.claimed_until is null
    and o.done_at is not null and o.last_error is null, row_to_json(o)::text);
end $$;

do $$
declare u uuid := pg_temp.owner('d2', '{990066903}'); q bigint; o msg.outbox; n int; j jsonb;
begin
  q := pg_temp.ev(u, 990066903, 'grid_down', 'd2:down');
  n := pg_temp.take();
  perform pg_temp.done(q, '{"code": 429, "retry_s": 7, "error": "resend 429"}');
  o := pg_temp.ob(q);
  perform pg_temp.ok('D2 429: back after Retry-After, try given back, counted',
    o.status = 'queued' and o.not_before = now() + interval '7 seconds' and o.tries = 0 and o.n429 = 1
    and o.last_429_at = now() and o.claim is null and o.done_at is null, row_to_json(o)::text);
  j := (select x from jsonb_array_elements(public.job_check_msg()) x where x->>'channel' = 'email' and x->>'lane' = 'urgent');
  perform pg_temp.ok('M1 job_check_msg: email lane listed, its 429 counted, the row waiting on Retry-After not due',
    (j->>'n429')::int >= 1 and (j->>'queued')::int >= 1
    and (j->>'oldest' is null or (j->>'oldest')::timestamptz > now() - interval '1 minute'), j::text);
  n := pg_temp.take();
  perform pg_temp.ok('D2 ... not taken before Retry-After', not pg_temp.taken(q));
  update msg.outbox set not_before = now() where id = o.id;
  n := pg_temp.take();
  perform pg_temp.ok('D2 ... taken after it, still first try', pg_temp.taken(q) and (pg_temp.ob(q)).tries = 1);
  perform pg_temp.done(q, '{"code": 503}');
  o := pg_temp.ob(q);
  perform pg_temp.ok('D3 5xx, no Retry-After: 60 s on try 1, the try kept',
    o.status = 'queued' and o.not_before = now() + interval '60 seconds' and o.tries = 1 and o.last_error = 'resend 503',
    row_to_json(o)::text);
  update msg.outbox set not_before = now() where id = o.id;
  n := pg_temp.take();
  perform pg_temp.done(q, '{"code": 0, "error": "resend: network"}');
  o := pg_temp.ob(q);
  perform pg_temp.ok('D4 no answer (0): again, doubling (try 2 = 120 s)',
    o.status = 'queued' and o.not_before = now() + interval '120 seconds' and o.last_error = 'resend: network', row_to_json(o)::text);
  update msg.outbox set not_before = now() where id = o.id;
  n := pg_temp.take();
  perform pg_temp.done(q, '{"untried": true}');
  o := pg_temp.ob(q);
  perform pg_temp.ok('D5 not tried (run out of time): back at once, try given back',
    o.status = 'queued' and o.not_before = now() and o.tries = 2 and o.claim is null, row_to_json(o)::text);
  n := pg_temp.take();
  perform pg_temp.done(q, '{"code": 422, "error": "resend 422: bad address"}');
  o := pg_temp.ob(q);
  perform pg_temp.ok('D6 422: failed, not tried again', o.status = 'failed' and o.done_at is not null
    and o.last_error like 'resend 422%', row_to_json(o)::text);
end $$;

do $$
declare u uuid := pg_temp.owner('d7', '{990066904}'); q bigint; q2 bigint; o msg.outbox; n int;
begin
  q := pg_temp.ev(u, 990066904, 'grid_down', 'd7:down', null, now() - interval '59 minutes');
  q2 := pg_temp.ev(u, 990066904, 'batt_hot', 'd7:hot');
  n := pg_temp.take();
  perform pg_temp.done(q, '{"code": 429, "retry_s": 120}');
  o := pg_temp.ob(q);
  perform pg_temp.ok('D7 a retry that would land past the hour: failed "too old"',
    o.status = 'failed' and o.last_error = 'too old' and o.done_at is not null, row_to_json(o)::text);
  perform pg_temp.ok('M2 job_check_msg counts it as expired',
    ((select x from jsonb_array_elements(public.job_check_msg()) x where x->>'channel' = 'email')->>'expired')::int >= 1);
  perform pg_temp.done(q2, '{"skip": "nothing to say"}');
  o := pg_temp.ob(q2);
  perform pg_temp.ok('D8 skip: dropped with the reason given', o.status = 'dropped' and o.drop_reason = 'nothing to say'
    and o.done_at is not null, row_to_json(o)::text);
end $$;

-- lost reply: the lease runs out, the row goes again under a new claim (same row id, so the
-- same Resend key); the old claim's late answer is ignored
do $$
declare u uuid := pg_temp.owner('l1', '{990066905}'); q bigint; n int; c1 uuid;
begin
  q := pg_temp.ev(u, 990066905, 'grid_down', 'l1:down');
  n := pg_temp.take();
  c1 := (select claim from t_take where event_id = q);
  update msg.outbox set claimed_until = now() - interval '1 second' where id = (pg_temp.ob(q)).id;
  n := pg_temp.take();
  perform pg_temp.ok('L1 lost reply: lease ran out, taken again under a new claim, same row',
    pg_temp.taken(q) and (select claim from t_take where event_id = q) <> c1
    and (select id from t_take where event_id = q) = (pg_temp.ob(q)).id and (pg_temp.ob(q)).tries = 2);
  perform public.msg_email_done(c1, jsonb_build_array(jsonb_build_object('id', (pg_temp.ob(q)).id, 'code', 200)));
  perform pg_temp.ok('L1 ... the late answer to the old claim is ignored', (pg_temp.ob(q)).status = 'queued');
  perform pg_temp.done(q, '{"code": 200}');
  perform pg_temp.ok('L1 ... the new claim closes it', (pg_temp.ob(q)).status = 'sent');
end $$;

-- ---------------------------------------------------------------------------
-- G: the guard at send time
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('g1', '{990066911,990066912,990066913}'); a uuid;
        q1 bigint; q2 bigint; q3 bigint; q4 bigint; q5 bigint; q6 bigint; q7 bigint; q8 bigint; q9 bigint; n int;
begin
  a := pg_temp.acc(u);
  q1 := pg_temp.ev(u, 990066911, 'grid_down', 'g1:old', null, now() - interval '61 minutes');
  q2 := pg_temp.ev(u, 990066912, 'grid_down', 'g1:removed');
  q3 := pg_temp.ev(u, 990066913, 'grid_down', 'g1:unchosen');
  q4 := pg_temp.ev(u, 990066911, 'batt_hot', 'g1:switch');
  q5 := pg_temp.ev(u, 990066912, 'needs_relink', 'g1:relink');
  q6 := pg_temp.ev(u, 990066911, 'grid_back', 'g1:back', 'g1:no-such-down');
  q7 := pg_temp.ev(u, 990066911, 'bank_drift_back', 'g1:drift-back');
  q8 := pg_temp.ev(u, 990066911, 'batt_hot_back', 'g1:hot-back');
  q9 := pg_temp.ev(u, 990066911, 'string_dead', 'g1:string');
  -- after queueing: plant removed, plant switched out, battery switch off
  delete from public.plant_users where user_id = u and plant_id = 990066912;
  perform billing.set_chosen_plants(a, '{990066911,990066912}', now());
  insert into public.email_prefs (user_id, battery) values (u, false);
  n := pg_temp.take();
  perform pg_temp.ok('G1 over an hour old: dropped "too old"', (pg_temp.ob(q1)).drop_reason = 'too old', (pg_temp.ob(q1)).drop_reason);
  perform pg_temp.ok('G2 plant removed', (pg_temp.ob(q2)).drop_reason = 'plant removed', (pg_temp.ob(q2)).drop_reason);
  perform pg_temp.ok('G3 plant not chosen', (pg_temp.ob(q3)).drop_reason = 'plant not chosen', (pg_temp.ob(q3)).drop_reason);
  perform pg_temp.ok('G4 switch off', (pg_temp.ob(q4)).drop_reason = 'switched off', (pg_temp.ob(q4)).drop_reason);
  perform pg_temp.ok('G5 reconnect: no switch, plant removed does not stop it', pg_temp.taken(q5), (pg_temp.ob(q5)).drop_reason);
  perform pg_temp.ok('G6 a "back" with no "down" row: dropped', (pg_temp.ob(q6)).drop_reason = 'down not sent',
    (pg_temp.ob(q6)).drop_reason);
  perform pg_temp.ok('G7 battery-hot and bank-drift "back": no email',
    (pg_temp.ob(q7)).drop_reason = 'no email for this kind' and (pg_temp.ob(q8)).drop_reason = 'no email for this kind');
  perform pg_temp.ok('G8 the rest goes', pg_temp.taken(q9));
  perform pg_temp.ok('G1 ... dropped rows are done', (pg_temp.ob(q1)).status = 'dropped' and (pg_temp.ob(q1)).done_at is not null);
end $$;

-- plant not live: its login needs reconnecting. Reconnect itself still goes.
do $$
declare u uuid := pg_temp.owner('g9', '{990066914}'); q bigint; r bigint; n int;
begin
  q := pg_temp.ev(u, 990066914, 'grid_down', 'g9:down');
  r := pg_temp.ev(u, 990066914, 'needs_relink', 'g9:relink');
  update billing.logins set status = 'needs_reconnect' where account = pg_temp.acc(u);
  n := pg_temp.take();
  perform pg_temp.ok('G9 plant not read any more: dropped "plant not live"',
    (pg_temp.ob(q)).drop_reason = 'plant not live', (pg_temp.ob(q)).drop_reason);
  perform pg_temp.ok('G9 ... reconnect on that plant still goes', pg_temp.taken(r), (pg_temp.ob(r)).drop_reason);
end $$;

-- review fixes: reconnect on a plant switched out still goes; dropped rows don't fill the take
do $$
declare u uuid := pg_temp.owner('g10', '{990066915,990066916}'); v uuid := pg_temp.owner('g11', '{990066917}');
        r bigint; d1 bigint; d2 bigint; d3 bigint; ok bigint; n int;
begin
  r := pg_temp.ev(u, 990066916, 'needs_relink', 'g10:relink');
  perform billing.set_chosen_plants(pg_temp.acc(u), '{990066915}', now());
  insert into public.email_prefs (user_id, grid) values (v, false);
  d1 := pg_temp.ev(v, 990066917, 'grid_down', 'g11:a', null, now() - interval '3 minutes');
  d2 := pg_temp.ev(v, 990066917, 'grid_down', 'g11:b', null, now() - interval '3 minutes');
  d3 := pg_temp.ev(v, 990066917, 'grid_down', 'g11:c', null, now() - interval '3 minutes');
  ok := pg_temp.ev(u, 990066915, 'grid_down', 'g10:down', null, now() - interval '2 minutes');
  n := pg_temp.take(2);
  perform pg_temp.ok('G10 reconnect on a plant no longer chosen: still goes', pg_temp.taken(r), (pg_temp.ob(r)).drop_reason);
  perform pg_temp.ok('G11 three dropped rows ahead: the take keeps going to the sendable one',
    pg_temp.taken(ok) and (pg_temp.ob(d3)).drop_reason = 'switched off', format('%s rows', n));
end $$;

-- ---------------------------------------------------------------------------
-- P: down/back pairs, both on the outbox
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('p1', '{990066921}'); down bigint; back bigint; n int;
begin
  down := pg_temp.ev(u, 990066921, 'grid_down', 'p1:down');
  back := pg_temp.ev(u, 990066921, 'grid_back', 'p1:back', 'p1:down');
  n := pg_temp.take();
  perform pg_temp.ok('P1 "back" waits while its "down" is leased',
    pg_temp.taken(down) and not pg_temp.taken(back) and (pg_temp.ob(back)).status = 'queued' and (pg_temp.ob(back)).claim is null);
  perform pg_temp.done(down, '{"code": 503}');
  n := pg_temp.take();
  perform pg_temp.ok('P1 ... and while it is queued for a retry', not pg_temp.taken(back) and (pg_temp.ob(back)).status = 'queued');
  update msg.outbox set not_before = now() where id = (pg_temp.ob(down)).id;
  n := pg_temp.take();
  perform pg_temp.done(down, '{"code": 200}');
  n := pg_temp.take();
  perform pg_temp.ok('P2 once the "down" is sent, the "back" goes', pg_temp.taken(back));
end $$;

do $$
declare u uuid := pg_temp.owner('p3', '{990066922}'); down bigint; back bigint; n int;
begin
  insert into public.email_prefs (user_id, grid) values (u, false);
  down := pg_temp.ev(u, 990066922, 'grid_down', 'p3:down');
  n := pg_temp.take();
  update public.email_prefs set grid = true where user_id = u;
  back := pg_temp.ev(u, 990066922, 'grid_back', 'p3:back', 'p3:down');
  n := pg_temp.take();
  perform pg_temp.ok('P3 "down" dropped (switch off then): "back" dropped "down not sent"',
    (pg_temp.ob(down)).drop_reason = 'switched off' and (pg_temp.ob(back)).drop_reason = 'down not sent');
end $$;

do $$
declare u uuid := pg_temp.owner('p4', '{990066923}'); down bigint; back bigint; n int;
begin
  down := pg_temp.ev(u, 990066923, 'grid_down', 'p4:down');
  back := pg_temp.ev(u, 990066923, 'grid_back', 'p4:back', 'p4:down');
  n := pg_temp.take();
  perform pg_temp.done(down, '{"code": 422}');
  perform pg_temp.ok('P4 "down" never dropped because of its "back"', (pg_temp.ob(down)).last_error = 'resend 422');
  n := pg_temp.take();
  perform pg_temp.ok('P4 ... "down" failed: "back" dropped', (pg_temp.ob(back)).drop_reason = 'down not sent',
    (pg_temp.ob(back)).drop_reason);
end $$;

-- waiting "back" rows never fill the take: with room for one row, the next row still goes
do $$
declare u uuid := pg_temp.owner('p5', '{990066924,990066925}'); down bigint; back bigint; other bigint; n int;
begin
  down := pg_temp.ev(u, 990066924, 'grid_down', 'p5:down');
  n := pg_temp.take();                                                    -- down leased
  back := pg_temp.ev(u, 990066924, 'grid_back', 'p5:back', 'p5:down', now() - interval '1 minute');
  other := pg_temp.ev(u, 990066925, 'grid_down', 'p5:other');
  n := pg_temp.take(1);
  perform pg_temp.ok('P5 a waiting "back" first in line does not block the next row', pg_temp.taken(other) and not pg_temp.taken(back));
  perform pg_temp.ok('M3 job_check_msg: a waiting "back" is not the oldest due',
    ((select x from jsonb_array_elements(public.job_check_msg()) x where x->>'channel' = 'email')->>'oldest') is null
    or ((select x from jsonb_array_elements(public.job_check_msg()) x where x->>'channel' = 'email')->>'oldest')::timestamptz
       > now() - interval '1 minute');
  update msg.outbox set claimed_until = now() - interval '1 second', not_before = now() - interval '10 minutes'
   where id = (pg_temp.ob(other)).id;
  perform pg_temp.ok('M4 ... a row whose lease ran out is',
    ((select x from jsonb_array_elements(public.job_check_msg()) x where x->>'channel' = 'email')->>'oldest')::timestamptz
       <= now() - interval '10 minutes');
end $$;

-- ---------------------------------------------------------------------------
-- X: a flip with rows in flight, a pair across the paths both ways, a flip back
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('x1', '{990066931}'); x bigint; y bigint; back bigint; n int; got bigint[];
begin
  update msg.kinds set route = 'old' where channel = 'email';
  x := pg_temp.ev(u, 990066931, 'grid_down', 'x1:down');               -- queued before the flip
  update msg.kinds set route = 'outbox' where channel = 'email';
  y := pg_temp.ev(u, 990066931, 'batt_hot', 'x1:hot');                  -- after it
  back := pg_temp.ev(u, 990066931, 'grid_back', 'x1:back', 'x1:down');  -- its "down" is on the old path
  n := pg_temp.take();
  perform pg_temp.ok('X1 flip in flight: the old row stays on the old path, no outbox row',
    pg_temp.ob(x) is null and (select status from public.email_queue where id = x) = 'queued');
  perform pg_temp.ok('X1 ... the new row goes through the outbox', pg_temp.taken(y));
  perform pg_temp.ok('X2 old "down" -> outbox "back": waits while the old "down" is queued',
    not pg_temp.taken(back) and (pg_temp.ob(back)).status = 'queued');
  got := array(select id from public.email_claim(100, false, 'urgent') where user_id = u);
  perform pg_temp.ok('X1 ... email_claim sends only the old row (no double)', got = array[x], got::text);
  n := pg_temp.take();
  perform pg_temp.ok('X2 ... and while it is sending', not pg_temp.taken(back));
  perform public.email_done(jsonb_build_array(jsonb_build_object('id', x, 'status', 'sent')));
  n := pg_temp.take();
  perform pg_temp.ok('X2 ... once the old "down" went, the "back" goes', pg_temp.taken(back));
end $$;

do $$
declare u uuid := pg_temp.owner('x3', '{990066932}'); down bigint; back bigint; n int; got bigint[];
begin
  down := pg_temp.ev(u, 990066932, 'grid_down', 'x3:down');            -- on the outbox
  update msg.kinds set route = 'old' where channel = 'email';           -- flip back
  back := pg_temp.ev(u, 990066932, 'grid_back', 'x3:back', 'x3:down');
  perform pg_temp.ok('X3 flip back: new rows go to the old path',
    pg_temp.ob(back) is null and (select status from public.email_queue where id = back) = 'queued');
  got := array(select id from public.email_claim(100, true, 'urgent') where user_id = u);
  perform pg_temp.ok('X3 outbox "down" -> old "back": email_claim waits while the "down" is queued', got = '{}', got::text);
  n := pg_temp.take();
  perform pg_temp.ok('X3 ... outbox rows made before the flip back still go', pg_temp.taken(down));
  got := array(select id from public.email_claim(100, true, 'urgent') where user_id = u);
  perform pg_temp.ok('X3 ... and while it is leased', got = '{}', got::text);
  perform pg_temp.done(down, '{"code": 200}');
  got := pg_temp.old_send(u);
  perform pg_temp.ok('X3 ... after the "down" went, email_claim sends the "back"', got = array[back], got::text);
  update msg.kinds set route = 'outbox' where channel = 'email';
end $$;

do $$
declare u uuid := pg_temp.owner('x4', '{990066933}'); down bigint; back bigint; n int;
begin
  down := pg_temp.ev(u, 990066933, 'grid_down', 'x4:down');
  n := pg_temp.take();
  perform pg_temp.done(down, '{"code": 400}');
  update msg.kinds set route = 'old' where channel = 'email';
  back := pg_temp.ev(u, 990066933, 'grid_back', 'x4:back', 'x4:down');
  perform pg_temp.old_send(u);
  perform pg_temp.ok('X4 old "back" after an outbox "down" that failed: skipped "down not sent"',
    (select (status, last_error) = ('skipped', 'down not sent') from public.email_queue where id = back),
    (select status || ' ' || last_error from public.email_queue where id = back));
  update msg.kinds set route = 'outbox' where channel = 'email';
end $$;

-- old "down" skipped (switch off), outbox "back": dropped
do $$
declare u uuid := pg_temp.owner('x5', '{990066934}'); down bigint; back bigint; n int;
begin
  insert into public.email_prefs (user_id, grid) values (u, false);
  update msg.kinds set route = 'old' where channel = 'email';
  down := pg_temp.ev(u, 990066934, 'grid_down', 'x5:down');
  perform pg_temp.old_send(u);
  update msg.kinds set route = 'outbox' where channel = 'email';
  update public.email_prefs set grid = true where user_id = u;
  back := pg_temp.ev(u, 990066934, 'grid_back', 'x5:back', 'x5:down');
  n := pg_temp.take();
  perform pg_temp.ok('X5 old "down" skipped: outbox "back" dropped "down not sent"',
    (select status from public.email_queue where id = down) = 'skipped' and (pg_temp.ob(back)).drop_reason = 'down not sent',
    (pg_temp.ob(back)).drop_reason);
end $$;

-- ---------------------------------------------------------------------------
-- B: batch key saved before the call; the group is fixed from then on
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('b1', '{990066941}'); a bigint; b bigint; o1 msg.outbox; c uuid; n int; failed boolean;
begin
  a := pg_temp.ev(u, 990066941, 'grid_down', 'b1:a');
  b := pg_temp.ev(u, 990066941, 'string_dead', 'b1:b');
  n := pg_temp.take();
  c := (select claim from t_take where event_id = a);
  perform public.msg_email_bind(c, 'mb-test-1', array[(pg_temp.ob(a)).id, (pg_temp.ob(b)).id]);
  perform pg_temp.ok('B1 bind: both rows carry the key',
    (pg_temp.ob(a)).batch_key = 'mb-test-1' and (pg_temp.ob(b)).batch_key = 'mb-test-1');
  begin
    perform public.msg_email_bind(gen_random_uuid(), 'mb-test-2', array[(pg_temp.ob(a)).id]);
    failed := false;
  exception when others then failed := true;
  end;
  perform pg_temp.ok('B1 ... under another claim, or already bound: refused, nothing changed',
    failed and (pg_temp.ob(a)).batch_key = 'mb-test-1');
  perform pg_temp.ok('B1 ... and their lease renewed', (pg_temp.ob(a)).claimed_until = now() + interval '2 minutes');
  -- the worker died after the call: lease runs out
  update msg.outbox set claimed_until = now() - interval '1 second' where batch_key = 'mb-test-1';
  n := pg_temp.take(1);
  perform pg_temp.ok('B2 lost reply: the group comes back together (even past the limit), key kept',
    pg_temp.taken(a) and pg_temp.taken(b) and (select bool_and(batch_key = 'mb-test-1') from t_take)
    and (pg_temp.ob(a)).tries = 2 and (pg_temp.ob(a)).status = 'queued', format('%s rows', n));
  perform public.msg_email_done((select claim from t_take limit 1), (select jsonb_agg(jsonb_build_object(
    'id', id, 'code', 503, 'keep', true)) from t_take));
  o1 := pg_temp.ob(a);
  perform pg_temp.ok('B3 5xx with keep: queued again, key kept', o1.status = 'queued' and o1.batch_key = 'mb-test-1'
    and o1.not_before > now(), row_to_json(o1)::text);
  update msg.outbox set not_before = now() where batch_key = 'mb-test-1';
  n := pg_temp.take();
  perform public.msg_email_done((select claim from t_take limit 1), (select jsonb_agg(jsonb_build_object(
    'id', id, 'code', 429, 'retry_s', 5, 'keep', true)) from t_take));
  perform pg_temp.ok('B4 429 on a bound group: key kept (its first call may have gone)',
    (pg_temp.ob(a)).batch_key = 'mb-test-1' and (pg_temp.ob(a)).n429 = 1);
  update msg.outbox set not_before = now() where batch_key = 'mb-test-1';
  n := pg_temp.take();
  perform public.msg_email_done((select claim from t_take limit 1), (select jsonb_agg(jsonb_build_object(
    'id', id, 'code', 200)) from t_take));
  perform pg_temp.ok('B5 sent: both sent, key cleared',
    (pg_temp.ob(a)).status = 'sent' and (pg_temp.ob(b)).status = 'sent' and (pg_temp.ob(a)).batch_key is null);
end $$;

do $$
declare u uuid := pg_temp.owner('b6', '{990066942}'); a bigint; b bigint; n int; c uuid;
begin
  a := pg_temp.ev(u, 990066942, 'grid_down', 'b6:a');
  b := pg_temp.ev(u, 990066942, 'string_dead', 'b6:b');
  n := pg_temp.take();
  c := (select claim from t_take limit 1);
  perform public.msg_email_bind(c, 'mb-test-6', array[(pg_temp.ob(a)).id, (pg_temp.ob(b)).id]);
  perform public.msg_email_done(c, jsonb_build_array(jsonb_build_object('id', (pg_temp.ob(a)).id, 'code', 422),
                                                     jsonb_build_object('id', (pg_temp.ob(b)).id, 'code', 200)));
  perform pg_temp.ok('B6 refused then each alone (no keep): keys cleared',
    (pg_temp.ob(a)).status = 'failed' and (pg_temp.ob(a)).batch_key is null and (pg_temp.ob(b)).batch_key is null);
end $$;

do $$
declare u uuid := pg_temp.owner('b7', '{990066943}'); a bigint; b bigint; c bigint; n int; cl uuid;
begin
  a := pg_temp.ev(u, 990066943, 'grid_down', 'b7:a', null, now() - interval '50 minutes');
  b := pg_temp.ev(u, 990066943, 'string_dead', 'b7:b');
  c := pg_temp.ev(u, 990066943, 'batt_hot', 'b7:c');
  n := pg_temp.take();
  cl := (select claim from t_take limit 1);
  perform public.msg_email_bind(cl, 'mb-test-7', array[(pg_temp.ob(a)).id, (pg_temp.ob(b)).id, (pg_temp.ob(c)).id]);
  perform public.msg_email_done(cl, (select jsonb_agg(jsonb_build_object('id', id, 'untried', true, 'keep', true)) from t_take));
  perform pg_temp.ok('B7 bound, handed back untried: key kept, try given back',
    (pg_temp.ob(a)).batch_key = 'mb-test-7' and (pg_temp.ob(a)).tries = 0 and (pg_temp.ob(a)).status = 'queued');
  update msg.outbox set expires_at = now() where id = (pg_temp.ob(a)).id;
  insert into public.email_prefs (user_id, panels) values (u, false);
  n := pg_temp.take();
  perform pg_temp.ok('B8 bound rows each pass the guard and their own expiry; the rest go under the key',
    (pg_temp.ob(a)).drop_reason = 'too old' and (pg_temp.ob(b)).drop_reason = 'switched off'
    and pg_temp.taken(c) and (select batch_key from t_take where event_id = c) = 'mb-test-7', format('%s rows', n));
end $$;

-- ---------------------------------------------------------------------------
-- S: who may call it; the flip
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.ok('S1 take, bind, done: service role only',
    has_function_privilege('service_role', 'public.msg_email_take(int, text)', 'execute')
    and has_function_privilege('service_role', 'public.msg_email_bind(uuid, text, bigint[])', 'execute')
    and not has_function_privilege('authenticated', 'public.msg_email_bind(uuid, text, bigint[])', 'execute')
    and has_function_privilege('service_role', 'public.msg_email_done(uuid, jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.msg_email_take(int, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.msg_email_done(uuid, jsonb)', 'execute'));
  perform pg_temp.ok('S2 every alert kind routes email to the outbox, urgent lane',
    (select count(*) from msg.kinds where channel = 'email' and route = 'outbox' and lane = 'urgent') = 14);
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
