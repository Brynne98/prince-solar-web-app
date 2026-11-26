-- SOLAR-645 step 5 (0263): the bulk emails through the message outbox.
-- LOCAL database only, with every migration applied. One transaction, rolled back:
--   psql "$DB" -v ON_ERROR_STOP=1 -f scripts/sql/msg-outbox-bulk-tests.sql
-- Exit 0: every check passed. A failed check raises, so psql exits 3.
-- now() is fixed in a transaction: "later" is made by moving times back.

begin;
set client_min_messages = notice;

create temp table t_results (n serial, label text, pass boolean, detail text);
create function pg_temp.ok(p_label text, p_cond boolean, p_detail text default null)
returns void language sql as $$
  insert into t_results (label, pass, detail) values (p_label, coalesce(p_cond, false), p_detail)
$$;
-- our plant id for a brand's id (SOLAR-681); the ids in the jsonb lists given to link_login are the brand's
create function pg_temp.pid(v bigint) returns bigint language sql as $$ select plants.plant_for('sunsynk', v::text) $$;
create function pg_temp.pids(v text) returns bigint[] language sql as $$
  select coalesce(array_agg(plants.plant_for('sunsynk', x) order by o), '{}') from unnest(v::text[]) with ordinality t(x, o)
$$;
create function pg_temp.link_login(a uuid, b text, n text, s uuid, p jsonb, at timestamptz default now(),
                                   actor text default 'owner', lid uuid default null) returns jsonb language plpgsql as $$
begin perform plants.link_login(a, b, n, p, at, actor, lid); return billing.account_state(a, at); end $$;
create function pg_temp.ep(p timestamptz) returns bigint language sql immutable as $$ select extract(epoch from p)::bigint $$;

-- an owner with chosen plants and a stored login (as msg-outbox-tests)
create function pg_temp.owner(p_name text, p_plants bigint[], p_at timestamptz default now() - interval '2 days')
returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); a uuid; l uuid := gen_random_uuid(); i int;
begin
  insert into auth.users (id, email, created_at) values (u, p_name || '@msgb.test', p_at);
  insert into billing.accounts (user_id, market, created_at) values (u, 'ZA', p_at) returning id into a;
  perform plants.link_login(a, 'sunsynk', p_name,
    (select jsonb_agg(jsonb_build_object('id', x, 'name', 'Plant ' || x)) from unnest(p_plants) x), p_at, 'owner', l);
  update plants.logins set last_ok_at = now(), last_try = 'ok', last_try_at = now() where id = l;
  for i in 1 .. cardinality(p_plants) loop
    update plants.login_plants set linked_at = p_at + (i - 1) * interval '1 hour'
     where login = l and plant = pg_temp.pid(p_plants[i]);
  end loop;
  insert into public.plant_config (plant_id) select pg_temp.pid(x) from unnest(p_plants) x on conflict (plant_id) do nothing;
  perform billing.set_chosen_plants(a, pg_temp.pids(p_plants::text), p_at);
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
-- the bulk lane's take
create function pg_temp.btake(p_limit int default 1000) returns int language plpgsql as $$
declare n int;
begin
  truncate t_take;
  insert into t_take select * from public.msg_email_take(p_limit, 'bulk');
  get diagnostics n = row_count;
  return n;
end $$;
-- a bulk event as its maker writes it
create function pg_temp.bev(p_user uuid, p_plant bigint, p_kind text, p_key text, p_data jsonb default '{}',
                            p_at timestamptz default now(), p_to text default null)
returns bigint language sql as $$
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority, created_at, due_at, to_email)
  values (p_user, p_plant, p_kind, p_key, p_data, case when p_kind like 'report\_%' then 2 else 1 end, p_at, p_at, p_to)
  returning id
$$;
-- a user with a login and plants on it, none chosen, no plan
create function pg_temp.picker(p_name text, p_plants bigint[]) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); a uuid; l uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, created_at) values (u, p_name || '@msgb.test', now() - interval '2 days');
  insert into billing.accounts (user_id, market, created_at) values (u, 'ZA', now() - interval '2 days') returning id into a;
  perform plants.link_login(a, 'sunsynk', p_name,
    (select jsonb_agg(jsonb_build_object('id', x, 'name', 'Plant ' || x)) from unnest(p_plants) x), now(), 'owner', l);
  update plants.logins set last_ok_at = now(), last_try = 'ok', last_try_at = now() where id = l;
  return u;
end $$;
-- ---------------------------------------------------------------------------
-- R: route at insert
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('r1', '{990068001}'); q bigint; o msg.outbox; f bigint; d bigint; s bigint;
begin
  q := pg_temp.bev(u, pg_temp.pid(990068001), 'report_week', 'r1:rep', jsonb_build_object('today', current_date));
  o := pg_temp.ob(q);
  perform pg_temp.ok('R1 report: event "outbox", one email row, bulk lane, 3-day expiry, address captured',
    (select status from public.email_queue where id = q) = 'outbox'
    and o.lane = 'bulk' and o.status = 'queued' and o.expires_at = now() + interval '3 days' and o.to_email = 'r1@msgb.test',
    row_to_json(o)::text);
  perform pg_temp.ok('R2 bulk rows stay out of the urgent take', pg_temp.take() >= 0 and not pg_temp.taken(q));
  f := pg_temp.bev(u, null, 'feedback', 'r1:fb', '{"message": "hi"}', now(), 'hello@princesolarhub.co.za');
  perform pg_temp.ok('R3 feedback: to hello@, 7 days', (pg_temp.ob(f)).to_email = 'hello@princesolarhub.co.za'
    and (pg_temp.ob(f)).expires_at = now() + interval '7 days');
  d := pg_temp.bev(null, null, 'account_deleted', 'account_deleted:r1', '{}', now(), 'gone@msgb.test');
  perform pg_temp.ok('R4 account deleted (no user): routed, address captured', (pg_temp.ob(d)).to_email = 'gone@msgb.test'
    and (pg_temp.ob(d)).user_id is null and (pg_temp.ob(d)).lane = 'bulk');
  s := pg_temp.bev(u, pg_temp.pid(990068001), 'need_a_hand', 'r1:hand', '{}', now() + interval '24 hours');
  perform pg_temp.ok('R5 need a hand: not before its due time, 2 days after it',
    (pg_temp.ob(s)).not_before = now() + interval '24 hours' and (pg_temp.ob(s)).expires_at = now() + interval '3 days');
  perform pg_temp.ok('R6 the bulk kinds, each with its expiry',
    (select string_agg(kind || '=' || ttl, ',' order by kind) from msg.kinds where channel = 'email' and lane = 'bulk' and route = 'outbox')
    = 'account_deleted=2 days,add_plant_reminder=2 days,feedback=7 days,history=1 day,need_a_hand=2 days,plant_off_login=2 days,report_month=3 days,'
      'report_week=3 days,report_year=3 days,share_removed=2 days,welcome=2 days');
  perform pg_temp.ok('R7 no pop-up row for a bulk kind', not exists (select 1 from msg.outbox where event_id = q and channel = 'push'));
end $$;

-- ---------------------------------------------------------------------------
-- K: the take's fields for the bulk kinds
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('k1', '{990068011}'); q bigint; h bigint; n int; t record;
begin
  q := pg_temp.bev(u, pg_temp.pid(990068011), 'report_week', 'k1:rep', jsonb_build_object('today', current_date, 'freeWeekEnds', true));
  h := pg_temp.bev(u, pg_temp.pid(990068011), 'need_a_hand', 'k1:hand');
  update public.email_prefs set reminders = true where user_id = u;  -- freeWeekEnds switch: reminders
  n := pg_temp.btake();
  select * into t from t_take where event_id = q;
  perform pg_temp.ok('K1 report: no free-week wording, the user''s unsubscribe token',
    t.id is not null and not (t.data ? 'freeWeekEnds') and t.data ? 'today'
    and t.unsub_token = (select unsub_token from public.email_prefs where user_id = u), row_to_json(t)::text);
  perform pg_temp.ok('K2 need a hand with plants already chosen: dropped (as G8)',
    (pg_temp.ob(h)).drop_reason = 'login added', (pg_temp.ob(h)).drop_reason);
end $$;

-- ---------------------------------------------------------------------------
-- G: the guard, per kind
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('g1', '{990068021,990068022,990068023}'); a uuid; v uuid := gen_random_uuid();
        w bigint; w2 bigint; h1 bigint; h2 bigint; r1 bigint; r2 bigint; r3 bigint; r4 bigint; s1 bigint; s2 bigint; n int;
begin
  a := pg_temp.acc(u);
  insert into auth.users (id, email, created_at) values (v, 'g1v@msgb.test', now());
  w := pg_temp.bev(u, null, 'welcome', 'g1:welcome');
  w2 := pg_temp.bev(v, null, 'welcome', 'g1v:welcome');
  h1 := pg_temp.bev(u, pg_temp.pid(990068021), 'history', 'g1:hist1');
  h2 := pg_temp.bev(u, pg_temp.pid(990068022), 'history', 'g1:hist2');
  r1 := pg_temp.bev(u, pg_temp.pid(990068021), 'report_week', 'g1:rep1', jsonb_build_object('today', current_date));
  r2 := pg_temp.bev(u, pg_temp.pid(990068023), 'report_week', 'g1:rep2', jsonb_build_object('today', current_date));
  r3 := pg_temp.bev(u, pg_temp.pid(990068021), 'report_month', 'g1:rep3', jsonb_build_object('today', current_date));
  r4 := pg_temp.bev(u, pg_temp.pid(990068021), 'report_year', 'g1:rep4', jsonb_build_object('today', current_date), now() - interval '3 days');
  s1 := pg_temp.bev(u, pg_temp.pid(990068023), 'share_removed', 'g1:share', '{"plants": ["Plant 990068023"]}');
  s2 := pg_temp.bev(u, pg_temp.pid(990068023), 'plant_off_login', 'g1:off', '{"plants": ["Plant 990068023"]}');
  -- after queueing: plant 2 removed, plant 3 switched out, monthly reports off
  delete from plants.login_plants where login in (select id from plants.logins where user_id = u) and plant = pg_temp.pid(990068022);
  perform billing.set_chosen_plants(a, pg_temp.pids('{990068021,990068022}'), now());
  insert into public.email_prefs (user_id, monthly) values (u, false) on conflict (user_id) do update set monthly = false;
  n := pg_temp.btake();
  perform pg_temp.ok('G1 welcome once a plant is linked: dropped', (pg_temp.ob(w)).drop_reason = 'plant linked', (pg_temp.ob(w)).drop_reason);
  perform pg_temp.ok('G1 ... welcome with no plant goes', pg_temp.taken(w2));
  perform pg_temp.ok('G2 history goes; plant removed: dropped', pg_temp.taken(h1) and (pg_temp.ob(h2)).drop_reason = 'plant removed',
    (pg_temp.ob(h2)).drop_reason);
  perform pg_temp.ok('G3 report goes; plant switched out: "report not wanted"', pg_temp.taken(r1)
    and (pg_temp.ob(r2)).drop_reason = 'report not wanted', (pg_temp.ob(r2)).drop_reason);
  perform pg_temp.ok('G4 report with its switch off', (pg_temp.ob(r3)).drop_reason = 'switched off', (pg_temp.ob(r3)).drop_reason);
  perform pg_temp.ok('G5 report past 3 days: "too old"', (pg_temp.ob(r4)).drop_reason = 'too old', (pg_temp.ob(r4)).drop_reason);
  perform pg_temp.ok('G6 share removed and plant off its login: go though the plant left the account',
    pg_temp.taken(s1) and pg_temp.taken(s2), coalesce((pg_temp.ob(s1)).drop_reason, '') || '/' || coalesce((pg_temp.ob(s2)).drop_reason, ''));
end $$;

-- history on a plant not read any more; need a hand
do $$
declare u uuid := pg_temp.owner('g7', '{990068031}'); p uuid := pg_temp.picker('g8', '{990068032}'); v uuid := gen_random_uuid();
        h bigint; n1 bigint; n2 bigint; n3 bigint; n int;
begin
  h := pg_temp.bev(u, pg_temp.pid(990068031), 'history', 'g7:hist');
  n1 := pg_temp.bev(u, null, 'need_a_hand', 'g7:hand');                  -- login added, plants chosen
  n2 := pg_temp.bev(p, null, 'need_a_hand', 'g8:hand');                  -- login added, plants wait to be chosen
  insert into auth.users (id, email, created_at) values (v, 'g9@msgb.test', now());
  n3 := pg_temp.bev(v, null, 'need_a_hand', 'g9:hand');                  -- no login
  update plants.logins set status = 'needs_reconnect' where account = pg_temp.acc(u);
  n := pg_temp.btake();
  perform pg_temp.ok('G7 history on a plant not read: dropped', (pg_temp.ob(h)).drop_reason = 'plant not live', (pg_temp.ob(h)).drop_reason);
  perform pg_temp.ok('G7 ... its event row marked skipped "not read", as email_claim did',
    (select status || '/' || last_error from public.email_queue where id = h) = 'skipped/not read');
  -- read again, history finishes again: email_on_history's two steps (0217)
  update plants.logins set status = 'ok' where account = pg_temp.acc(u);
  delete from public.email_queue q where q.plant_id = pg_temp.pid(990068031) and q.kind = 'history' and q.status = 'skipped' and q.last_error = 'not read';
  perform private.email_enqueue_plant(pg_temp.pid(990068031), 'history', 'history:990068031', '{}'::jsonb, null, 1::smallint);
  perform pg_temp.ok('G7 ... queued again through the outbox once the plant is read',
    exists (select 1 from public.email_queue q join msg.outbox o on o.dedupe_key = q.id || ':email'
             where q.user_id = u and q.key = 'history:990068031' and q.status = 'outbox' and o.status = 'queued'));
  update plants.logins set status = 'needs_reconnect' where account = pg_temp.acc(u);
  perform pg_temp.ok('G8 need a hand once a login is added: dropped', (pg_temp.ob(n1)).drop_reason = 'login added', (pg_temp.ob(n1)).drop_reason);
  perform pg_temp.ok('G8 ... plants waiting to be chosen: goes, choose plants', pg_temp.taken(n2)
    and ((select data from t_take where event_id = n2)->>'choose')::boolean is true, (pg_temp.ob(n2)).drop_reason);
  perform pg_temp.ok('G8 ... no login: goes, no choose', pg_temp.taken(n3) and not ((select data from t_take where event_id = n3) ? 'choose'));
end $$;

-- ---------------------------------------------------------------------------
-- H: holds
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('h1', '{990068041}'); q bigint; o msg.outbox; n int; hist bigint;
begin
  q := pg_temp.bev(u, pg_temp.pid(990068041), 'report_week', 'h1:rep', jsonb_build_object('today', current_date));
  n := pg_temp.btake();
  update msg.outbox set batch_key = 'mb-h1' where id = (pg_temp.ob(q)).id;   -- as if bound, to see it cleared
  perform pg_temp.done(q, '{"hold_s": 600, "error": "waits for history"}');
  o := pg_temp.ob(q);
  perform pg_temp.ok('H1 hold: back in 10 minutes, try given back, key cleared, reason kept, not done',
    o.status = 'queued' and o.not_before = now() + interval '600 seconds' and o.tries = 0 and o.batch_key is null
    and o.last_error = 'waits for history' and o.done_at is null and o.claim is null and o.n429 = 0, row_to_json(o)::text);
  n := pg_temp.btake();
  perform pg_temp.ok('H1 ... not taken before then', not pg_temp.taken(q));
  update msg.outbox set not_before = now() where id = o.id;
  n := pg_temp.btake();
  perform pg_temp.ok('H1 ... taken after, first try again', pg_temp.taken(q) and (pg_temp.ob(q)).tries = 1);
  update msg.outbox set expires_at = now() + interval '5 minutes' where id = o.id;
  perform pg_temp.done(q, '{"hold_s": 3600, "error": "nothing to say yet"}');
  o := pg_temp.ob(q);
  perform pg_temp.ok('H2 a hold past the expiry: dropped with its reason, not "too old"',
    o.status = 'dropped' and o.drop_reason = 'nothing to say yet' and o.done_at is not null, row_to_json(o)::text);
  -- email_history_open: on the outbox
  hist := pg_temp.bev(u, pg_temp.pid(990068041), 'history', 'h1:hist');
  perform pg_temp.ok('H3 history on its way (outbox): open', public.email_history_open(u, pg_temp.pid(990068041)));
  n := pg_temp.btake();
  perform pg_temp.ok('H3 ... while leased: open', public.email_history_open(u, pg_temp.pid(990068041)));
  perform pg_temp.done(hist, '{"code": 200}');
  perform pg_temp.ok('H3 ... once sent: not open', not public.email_history_open(u, pg_temp.pid(990068041)));
  perform pg_temp.ok('H5 service role only',
    has_function_privilege('service_role', 'public.email_history_open(uuid, bigint)', 'execute')
    and not has_function_privilege('authenticated', 'public.email_history_open(uuid, bigint)', 'execute'));
end $$;

-- ---------------------------------------------------------------------------
-- F, A, N: feedback scrub, account deleted, need-a-hand sent time
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('f1', '{990068051}'); f bigint; f2 bigint; n int; t record;
begin
  f := pg_temp.bev(u, null, 'feedback', 'feedback:f1', jsonb_build_object('id', 41, 'message', 'hello', 'image', 'QUJD',
                                                                           'email', 'f1@msgb.test'), now(), 'hello@princesolarhub.co.za');
  f2 := pg_temp.bev(u, null, 'feedback', 'feedback:f2', jsonb_build_object('id', 42, 'message', 'again', 'image', 'QUJD'),
                    now(), 'hello@princesolarhub.co.za');
  n := pg_temp.btake();
  select * into t from t_take where event_id = f;
  perform pg_temp.ok('F1 feedback taken with its message and screenshot, to hello@',
    t.to_email = 'hello@princesolarhub.co.za' and t.data->>'image' = 'QUJD' and t.data->>'message' = 'hello', row_to_json(t)::text);
  perform pg_temp.done(f, '{"code": 200}');
  perform pg_temp.ok('F1 ... sent: message and screenshot gone from the event row, sent time kept',
    (select data from public.email_queue where id = f) = '{"id": 41}'::jsonb
    and (select sent_at from public.email_queue where id = f) = now());
  perform pg_temp.done(f2, '{"code": 503}');
  perform pg_temp.ok('F2 ... a retry keeps them', (select data from public.email_queue where id = f2) ? 'image');
  perform pg_temp.done(f2, '{}');  -- not leased any more: ignored
  update msg.outbox set claimed_until = null, not_before = now() where id = (pg_temp.ob(f2)).id;
  n := pg_temp.btake();
  perform pg_temp.done(f2, '{"code": 422, "error": "bad"}');
  perform pg_temp.ok('F2 ... refused: gone too', (select data from public.email_queue where id = f2) = '{"id": 42}'::jsonb
    and (select sent_at from public.email_queue where id = f2) is null);
end $$;

do $$
declare u uuid := gen_random_uuid(); d bigint; d2 bigint; o msg.outbox; n int; t record;
begin
  -- api_account_delete: the address on the row, then the person goes
  insert into auth.users (id, email, created_at) values (u, 'a1@msgb.test', now());
  insert into public.email_queue (to_email, kind, key, priority)
  values ('a1@msgb.test', 'account_deleted', 'account_deleted:' || u, 1) returning id into d;
  delete from auth.users where id = u;
  d2 := pg_temp.bev(null, null, 'account_deleted', 'account_deleted:a2', '{}', now(), 'a2@msgb.test');
  o := pg_temp.ob(d);
  n := pg_temp.btake();
  select * into t from t_take where event_id = d;
  perform pg_temp.ok('A1 account deleted: no user, taken with the captured address', t.to_email = 'a1@msgb.test'
    and t.user_id is null and t.tz = 'Africa/Johannesburg', row_to_json(t)::text);
  perform pg_temp.done(d, '{"code": 200}');
  perform pg_temp.ok('A1 ... sent: event row and outbox row deleted, address and all',
    not exists (select 1 from public.email_queue where id = d) and not exists (select 1 from msg.outbox where id = o.id));
  perform pg_temp.done(d2, '{"code": 503}');
  perform pg_temp.ok('A2 ... a retry keeps it', exists (select 1 from public.email_queue where id = d2));
  update msg.outbox set claimed_until = null, not_before = now() where event_id = d2;
  n := pg_temp.btake();
  perform pg_temp.done(d2, '{"code": 422, "error": "bad"}');
  perform pg_temp.ok('A2 ... refused: deleted too', not exists (select 1 from public.email_queue where id = d2)
    and not exists (select 1 from msg.outbox where event_id = d2));
end $$;

do $$
declare v uuid := gen_random_uuid(); h bigint; n int;
begin
  insert into auth.users (id, email, created_at) values (v, 'n1@msgb.test', now());
  h := pg_temp.bev(v, null, 'need_a_hand', 'need_a_hand');
  n := pg_temp.btake();
  perform pg_temp.done(h, '{"code": 200}');
  perform pg_temp.ok('N1 need a hand sent: the event row has its sent time (link-sunsynk reads it), status kept "outbox"',
    (select sent_at from public.email_queue where id = h) = now() and (select status from public.email_queue where id = h) = 'outbox');
end $$;

-- ---------------------------------------------------------------------------
-- L, D: lost reply, 429, batch key on a bulk group
-- ---------------------------------------------------------------------------
do $$
declare u uuid := pg_temp.owner('l1', '{990068061}'); q bigint; q2 bigint; n int; c1 uuid; o msg.outbox; j jsonb;
begin
  q := pg_temp.bev(u, pg_temp.pid(990068061), 'history', 'l1:hist');
  q2 := pg_temp.bev(u, pg_temp.pid(990068061), 'report_week', 'l1:rep', jsonb_build_object('today', current_date));
  n := pg_temp.btake();
  c1 := (select claim from t_take where event_id = q);
  perform public.msg_email_bind(c1, 'mb-l1', array[(pg_temp.ob(q)).id, (pg_temp.ob(q2)).id]);
  update msg.outbox set claimed_until = now() - interval '1 second' where event_id in (q, q2) and channel = 'email';
  n := pg_temp.btake();
  perform pg_temp.ok('L1 lost reply on a bulk batch: both back under a new claim, key kept',
    pg_temp.taken(q) and pg_temp.taken(q2) and (select claim from t_take where event_id = q) <> c1
    and (select count(distinct batch_key) from t_take where event_id in (q, q2) and batch_key = 'mb-l1') = 1);
  perform public.msg_email_done(c1, jsonb_build_array(jsonb_build_object('id', (pg_temp.ob(q)).id, 'code', 200)));
  perform pg_temp.ok('L1 ... the late answer to the old claim is ignored', (pg_temp.ob(q)).status = 'queued');
  perform pg_temp.done(q, '{"code": 429, "retry_s": 9, "error": "resend 429", "keep": true}');
  o := pg_temp.ob(q);
  perform pg_temp.ok('D1 429 on bulk: after Retry-After, try given back, counted, key kept',
    o.status = 'queued' and o.not_before = now() + interval '9 seconds' and o.n429 = 1 and o.tries = 1 and o.batch_key = 'mb-l1',
    row_to_json(o)::text);
  j := (select x from jsonb_array_elements(public.job_check_msg()) x where x->>'channel' = 'email' and x->>'lane' = 'bulk');
  perform pg_temp.ok('M1 job_check_msg: the email bulk lane is listed, its 429 counted',
    j is not null and (j->>'n429')::int >= 1 and (j->>'queued')::int >= 1, j::text);
  perform pg_temp.done(q2, '{"code": 200}');
  perform pg_temp.ok('D2 the rest of the group: sent', (pg_temp.ob(q2)).status = 'sent');
end $$;

-- ---------------------------------------------------------------------------
-- X: no way back (0265)
-- ---------------------------------------------------------------------------
do $$
declare refused boolean := false;
begin
  begin
    update msg.kinds set route = 'old' where channel = 'email' and lane = 'bulk';
  exception when check_violation then refused := true;
  end;
  perform pg_temp.ok('X1 a bulk kind can no longer go back to the old path', refused);
end $$;

-- ---------------------------------------------------------------------------
-- S: grants
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.ok('S1 take and done: service role only',
    has_function_privilege('service_role', 'public.msg_email_take(int, text)', 'execute')
    and not has_function_privilege('anon', 'public.msg_email_take(int, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.msg_email_take(int, text)', 'execute')
    and has_function_privilege('service_role', 'public.msg_email_done(uuid, jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'public.msg_email_done(uuid, jsonb)', 'execute'));
end $$;

-- ---------------------------------------------------------------------------
-- P: add your plant, 7 days after sign-up (SOLAR-474, 0274)
-- ---------------------------------------------------------------------------
do $$
declare v uuid := gen_random_uuid(); w uuid := gen_random_uuid(); x uuid := gen_random_uuid(); y uuid := gen_random_uuid();
        u uuid := pg_temp.picker('a2', '{990068091}'); sl uuid; ev bigint; e2 bigint; e3 bigint; n int;
begin
  -- confirmed at sign-up: queued with welcome and need a hand, due in 7 days
  insert into auth.users (id, email, created_at, email_confirmed_at) values (v, 'a1@msgb.test', now(), now());
  select id into ev from public.email_queue where user_id = v and kind = 'add_plant_reminder';
  perform pg_temp.ok('P1 confirm queues it: through the outbox, bulk, due in 7 days, 2 days after',
    (select status from public.email_queue where id = ev) = 'outbox'
    and (pg_temp.ob(ev)).lane = 'bulk' and (pg_temp.ob(ev)).not_before = now() + interval '7 days'
    and (pg_temp.ob(ev)).expires_at = now() + interval '9 days', row_to_json(pg_temp.ob(ev))::text);
  update auth.users set email_confirmed_at = null where id = v;
  update auth.users set email_confirmed_at = now() where id = v;
  perform pg_temp.ok('P2 confirming again: still one per account',
    (select count(*) from public.email_queue where user_id = v and kind = 'add_plant_reminder') = 1);
  -- confirmed before 0274: its rows gone, as if queued before; any later change queues none
  insert into auth.users (id, email, created_at, email_confirmed_at) values (x, 'a0@msgb.test', now(), now());
  delete from public.email_queue where user_id = x;
  update auth.users set email = 'a0b@msgb.test', email_confirmed_at = now() where id = x;
  perform pg_temp.ok('P3 an account confirmed before this gets none',
    not exists (select 1 from public.email_queue where user_id = x));
  n := pg_temp.btake();
  perform pg_temp.ok('P4 not taken before day 7', not pg_temp.taken(ev));
  -- day 7: the dates moved back
  update msg.outbox set not_before = now() - interval '1 minute', expires_at = now() + interval '2 days'
   where dedupe_key = ev || ':email';
  -- a login linked by then; a claimed shared plant and no login of its own
  insert into auth.users (id, email, created_at) values (w, 'a3@msgb.test', now());
  select id into sl from plants.logins where kind = 'share';
  if sl is null then
    insert into auth.users (id, email, created_at) values (y, 'share@msgb.test', now());
    insert into plants.logins (user_id, brand, username, status, kind) values (y, 'sunsynk', 'share@msgb.test', 'ok', 'share')
    returning id into sl;
  end if;
  perform plants.claim(billing.account_of(w, true), 'sunsynk', '990068092', 'Plant 990068092');
  e2 := pg_temp.bev(u, null, 'add_plant_reminder', 'a2:add');
  e3 := pg_temp.bev(w, null, 'add_plant_reminder', 'a3:add');
  n := pg_temp.btake();
  perform pg_temp.ok('P5 day 7, no login and no plant: goes, from the queue row',
    pg_temp.taken(ev) and (select kind from t_take where event_id = ev) = 'add_plant_reminder'
    and (select to_email from t_take where event_id = ev) = 'a1@msgb.test', (pg_temp.ob(ev)).drop_reason);
  perform pg_temp.ok('P6 a login added by then, no plant: dropped', (pg_temp.ob(e2)).drop_reason = 'login or plant added', (pg_temp.ob(e2)).drop_reason);
  perform pg_temp.ok('P7 a shared plant claimed, no login: dropped', (pg_temp.ob(e3)).drop_reason = 'login or plant added', (pg_temp.ob(e3)).drop_reason);
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
