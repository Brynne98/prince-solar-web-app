-- SOLAR-645 step 1 (0256): the three fixes on the old alert queue; F4 is 0258.
-- LOCAL database only, with every migration applied. One transaction, rolled back:
--   psql "$DB" -v ON_ERROR_STOP=1 -f scripts/sql/alert-queue-tests.sql
-- Exit 0: every check passed. A failed check raises, so psql exits 3.
-- The sweep and plant_live read now(), so the clock here is now() (fixed in a transaction).

begin;
-- These checks drive push_claim and email_claim (the old paths). Since 0261 pop-ups and since
-- 0262 alert emails go through the outbox; put them back on the old paths for this
-- rolled-back transaction.
update msg.kinds set route = 'old';
set client_min_messages = notice;

create temp table t_results (n serial, label text, pass boolean, detail text);
create function pg_temp.ok(p_label text, p_cond boolean, p_detail text default null)
returns void language sql as $$
  insert into t_results (label, pass, detail) values (p_label, coalesce(p_cond, false), p_detail)
$$;
create function pg_temp.ago(p interval) returns timestamptz language sql stable as $$ select now() - p $$;
create function pg_temp.ep(p timestamptz) returns bigint language sql immutable as $$ select extract(epoch from p)::bigint $$;

-- an owner: user, billing account, stored login (private and billing share its id), plants
-- linked oldest first, an hour apart
create function pg_temp.owner(p_name text, p_plants bigint[], p_at timestamptz) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); a uuid; l uuid := gen_random_uuid(); i int;
begin
  insert into auth.users (id, email, created_at) values (u, p_name || '@alerts.test', p_at);
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
  return a;
end $$;
create function pg_temp.uid(p_acc uuid) returns uuid language sql as $$ select user_id from billing.accounts where id = p_acc $$;
create function pg_temp.login(p_acc uuid) returns uuid language sql as $$ select id from billing.logins where account = p_acc $$;

-- ---------------------------------------------------------------------------
-- F1 push_claim: a plant switched out after its alert was queued gets no pop-up.
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.owner('f1', '{990064501,990064502}', pg_temp.ago('2 days')); u uuid; got bigint[]; q1 bigint; q2 bigint;
begin
  u := pg_temp.uid(a);
  perform billing.set_chosen_plants(a, '{990064501}', pg_temp.ago('2 days'));
  insert into public.push_subs (user_id, platform, endpoint, p256dh, auth) values (u, 'web', 'https://fcm.googleapis.com/fcm/send/alerts-test-f1', 'k', 'a');
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
  values (u, 990064501, 'grid_down', 'grid_down:f1:1', jsonb_build_object('since', pg_temp.ep(now())), 0) returning id into q1;
  -- the owner switches to the other plant before the pop-up goes
  perform billing.set_chosen_plants(a, '{990064502}', now());
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
  values (u, 990064502, 'grid_down', 'grid_down:f1:2', jsonb_build_object('since', pg_temp.ep(now())), 0) returning id into q2;
  got := array(select id from public.push_claim(200) where user_id = u);
  perform pg_temp.ok('F1 unchosen plant: no pop-up', not (q1 = any (got)), got::text);
  perform pg_temp.ok('F1 ... marked "plant not chosen"',
    (select push_skip from public.email_queue where id = q1) = 'plant not chosen',
    (select push_skip from public.email_queue where id = q1));
  perform pg_temp.ok('F1 chosen plant: pop-up goes', q2 = any (got), got::text);
end $$;

-- ---------------------------------------------------------------------------
-- F3 "No readings" waits 30 min after reading starts again (before F2: F2 turns
-- SunSynk "down", which stops this check).
-- ---------------------------------------------------------------------------
create function pg_temp.quiet(p_plant bigint, p_started timestamptz) returns void language sql as $$
  insert into private.plant_alert_state (plant_id, last_dev, stale, started_at)
  values (p_plant, pg_temp.ep(pg_temp.ago('10 days')), false, pg_temp.ep(p_started))
  on conflict (plant_id) do update set last_dev = excluded.last_dev, stale = false, stale_key = null,
                                       started_at = excluded.started_at
$$;
create function pg_temp.stale_sent(p_plant bigint) returns boolean language sql as $$
  select exists (select 1 from public.email_queue where kind = 'logger_stale' and plant_id = p_plant)
$$;
create function pg_temp.started(p_plant bigint) returns bigint language sql as $$
  select started_at from private.plant_alert_state where plant_id = p_plant
$$;

do $$
declare a uuid := pg_temp.owner('f3', '{990064601}', pg_temp.ago('20 days'));
        g uuid := pg_temp.owner('f3g', '{990064611}', pg_temp.ago('20 days'));
        c uuid := pg_temp.owner('f3c', '{990064621,990064622}', pg_temp.ago('20 days'));
        s uuid; inv uuid; ref text; r jsonb;
begin
  -- free week 20 days ago, over 13 days ago: nothing read since; the seat stays open
  perform billing.set_chosen_plants(a, '{990064601}', pg_temp.ago('20 days'));
  perform pg_temp.quiet(990064601, pg_temp.ago('20 days'));
  perform pg_temp.ok('F3 set-up: week over, seat open',
    (billing.account_status(a, now())).state = 'ended'
    and exists (select 1 from billing.seats where account = a and plant = 990064601 and closed_at is null));

  -- the plan paid again now, through the real checkout and payment
  inv := (billing.start_checkout(a, 'home', 'month', 0, '{990064601}', now())->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', now())->>'reference';
  r := billing.apply_payment(ref, jsonb_build_object('status', 'success', 'reference', ref, 'currency', 'ZAR',
         'gateway_response', 'Approved', 'amount', (select amount_minor from billing.payment_attempts where reference = ref),
         'authorization', jsonb_build_object('authorization_code', 'AUTH_f3', 'reusable', true, 'last4', '0003',
                                             'exp_month', '12', 'exp_year', '2030', 'card_type', 'visa', 'signature', 'SIG_f3'),
         'customer', jsonb_build_object('email', 'f3@alerts.test', 'customer_code', 'CUS_f3')), now());
  perform pg_temp.ok('F3 plan restart applied', r->>'action' = 'applied' and r->>'kind' = 'purchase', r::text);
  perform pg_temp.ok('F3 restart: "No readings" counts from now', pg_temp.started(990064601) = pg_temp.ep(now()),
    pg_temp.started(990064601)::text);
  perform public.email_sweep();
  perform pg_temp.ok('F3 restart: no "No readings" in the first 30 min', not pg_temp.stale_sent(990064601));
  -- control: the same plant 31 minutes on does alert
  update private.plant_alert_state set started_at = pg_temp.ep(pg_temp.ago('31 minutes')) where plant_id = 990064601;
  perform public.email_sweep();
  perform pg_temp.ok('F3 control: after 30 min it alerts', pg_temp.stale_sent(990064601));

  -- a grant on an ended account
  perform billing.set_chosen_plants(g, '{990064611}', pg_temp.ago('20 days'));
  perform pg_temp.quiet(990064611, pg_temp.ago('20 days'));
  insert into billing.grants (account, places, reason, starts_at) values (g, 1, 'test', now());
  perform pg_temp.ok('F3 grant: "No readings" counts from now', pg_temp.started(990064611) = pg_temp.ep(now()),
    pg_temp.started(990064611)::text);
  perform public.email_sweep();
  perform pg_temp.ok('F3 grant: no "No readings" in the first 30 min', not pg_temp.stale_sent(990064611));

  -- a new seat while the account reads: only the new plant starts again
  perform billing.set_chosen_plants(c, '{990064621}', pg_temp.ago('1 day'));
  perform pg_temp.quiet(990064621, pg_temp.ago('1 day'));
  perform pg_temp.quiet(990064622, pg_temp.ago('1 day'));
  perform billing.set_chosen_plants(c, '{990064621,990064622}', now());
  perform pg_temp.ok('F3 seat chosen: the new plant counts from now', pg_temp.started(990064622) = pg_temp.ep(now()));
  perform pg_temp.ok('F3 seat chosen: the plant already read keeps its start',
    pg_temp.started(990064621) = pg_temp.ep(pg_temp.ago('1 day')));

  -- a second owner chooses a plant another owner already reads: its start stays
  perform billing.set_chosen_plants(c, '{990064621,990064622}', now());
  s := pg_temp.owner('f3s', '{990064621}', pg_temp.ago('1 day'));
  insert into billing.grants (account, places, reason, starts_at) values (s, 1, 'test', now());
  update private.plant_alert_state set started_at = pg_temp.ep(pg_temp.ago('1 day')) where plant_id = 990064621;
  perform billing.set_chosen_plants(s, '{990064621}', now());
  perform pg_temp.ok('F3 shared plant: a second owner choosing it keeps its start',
    pg_temp.started(990064621) = pg_temp.ep(pg_temp.ago('1 day')), pg_temp.started(990064621)::text);
end $$;

-- ---------------------------------------------------------------------------
-- F4 (0258) a grant that starts later does not silence "No readings" today.
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.owner('f4', '{990064801}', pg_temp.ago('20 days'));
begin
  perform billing.set_chosen_plants(a, '{990064801}', pg_temp.ago('20 days'));
  insert into billing.grants (account, places, reason, starts_at, ends_at) values (a, 1, 'now', pg_temp.ago('1 day'), now() + interval '7 days');
  perform pg_temp.quiet(990064801, pg_temp.ago('1 day'));
  -- the next grant starts after this one ends: held then, so 0256 writes its start
  insert into billing.grants (account, places, reason, starts_at) values (a, 1, 'later', now() + interval '14 days');
  perform pg_temp.ok('F4 set-up: start written in the future', pg_temp.started(990064801) > pg_temp.ep(now()),
    pg_temp.started(990064801)::text);
  perform public.email_sweep();
  perform pg_temp.ok('F4 plant read today still alerts', pg_temp.stale_sent(990064801));
end $$;

-- ---------------------------------------------------------------------------
-- F2 "SunSynk is down" goes on the oldest chosen plant, not the oldest plant.
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.owner('f2', '{990064701,990064702}', pg_temp.ago('2 days')); u uuid; r public.email_queue;
begin
  u := pg_temp.uid(a);
  -- 990064701 is the oldest; only 990064702 is chosen
  perform billing.set_chosen_plants(a, '{990064702}', pg_temp.ago('2 days'));
  -- every login fails on SunSynk's side: only this test's logins are tried
  update private.sunsynk_accounts set last_try_at = pg_temp.ago('1 hour') where id <> pg_temp.login(a);
  update private.sunsynk_accounts set last_try = 'sunsynk', last_try_at = now(), last_ok_at = pg_temp.ago('1 hour')
   where id = pg_temp.login(a);
  perform public.email_sweep();
  select * into r from public.email_queue where user_id = u and kind = 'sunsynk_down';
  perform pg_temp.ok('F2 "SunSynk is down" queued, not dropped', r.id is not null);
  perform pg_temp.ok('F2 ... on the chosen plant', r.plant_id = 990064702, coalesce(r.plant_id::text, 'none'));
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
