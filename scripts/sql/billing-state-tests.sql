-- SOLAR-641 state test: every walk-through in reports/billing-redesign-2026-11-22.md,
-- run against billing.account_state / plant_state with a moved clock (each call takes `at`).
-- Run by scripts/billing-state-test.mjs inside one transaction that is rolled back.
-- Payment, cancel and plan changes have no command yet (later phases): the test writes
-- those subscription rows directly, the way those commands will.

set client_min_messages = notice;

create temp table t_results (n serial, label text, pass boolean, detail text);

create function pg_temp.ok(p_label text, p_cond boolean, p_detail text default null)
returns void language sql as $$
  insert into t_results (label, pass, detail) values (p_label, coalesce(p_cond, false), p_detail)
$$;
create function pg_temp.eq(p_label text, p_got text, p_want text)
returns void language sql as $$
  insert into t_results (label, pass, detail)
  values (p_label, p_got is not distinct from p_want, format('got %s, want %s', coalesce(p_got, 'null'), coalesce(p_want, 'null')))
$$;
create function pg_temp.eqt(p_label text, p_got text, p_want timestamptz)
returns void language sql as $$
  insert into t_results (label, pass, detail)
  values (p_label, p_got::timestamptz is not distinct from p_want, format('got %s, want %s', coalesce(p_got, 'null'), coalesce(p_want::text, 'null')))
$$;
create function pg_temp.fails(p_label text, p_sql text, p_like text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    insert into t_results (label, pass, detail) values (p_label, sqlerrm ilike '%' || p_like || '%', sqlerrm);
    return;
  end;
  insert into t_results (label, pass, detail) values (p_label, false, 'no error');
end $$;

-- the clock: day 0 is 1 Dec 2026, 10:00 in Johannesburg
create function pg_temp.t(p_days numeric) returns timestamptz language sql immutable as $$
  select '2026-12-01 10:00+02'::timestamptz + p_days * interval '1 day'
$$;
create function pg_temp.acct(p_name text) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid(); a uuid;
begin
  insert into auth.users (id, email, created_at) values (u, p_name || '@state.test', pg_temp.t(0));
  insert into billing.accounts (user_id, market, created_at) values (u, 'ZA', pg_temp.t(0)) returning id into a;
  return a;
end $$;
create function pg_temp.link(p_acc uuid, p_user text, p_plants bigint[], p_at timestamptz) returns uuid language plpgsql as $$
begin
  perform billing.link_login(p_acc, 'sunsynk', p_user, null,
    (select jsonb_agg(jsonb_build_object('id', x, 'name', 'Plant ' || x)) from unnest(p_plants) x), p_at);
  return (select id from billing.logins where account = p_acc and username = p_user);
end $$;
create function pg_temp.choose(p_acc uuid, p_plants bigint[], p_at timestamptz) returns jsonb language sql as $$
  select billing.set_chosen_plants(p_acc, p_plants, p_at)
$$;
-- Stands in for start_checkout + apply_payment (phase 3): a new plan from p_at; paying ends the week.
create function pg_temp.pay(p_acc uuid, p_plan text, p_interval text, p_at timestamptz, p_offer text default null)
returns uuid language plpgsql as $$
declare pr billing.prices; s uuid;
begin
  select * into pr from billing.prices where plan = p_plan and market = 'ZA' and interval = p_interval
     and offer is not distinct from p_offer and active_until is null;
  insert into billing.subscriptions (account, price, plan, currency, interval, amount_minor, extra_place_minor, offer,
                                     status, started_at, billing_day, period_start, period_end)
  values (p_acc, pr.id, p_plan, 'ZAR', p_interval, pr.amount_minor, pr.extra_place_minor, p_offer, 'active', p_at,
          extract(day from p_at at time zone 'Africa/Johannesburg'), p_at,
          p_at + case p_interval when 'year' then interval '1 year' else interval '1 month' end)
  returning id into s;
  update billing.accounts set trial_ends_at = least(trial_ends_at, p_at) where id = p_acc and trial_started_at is not null;
  return s;
end $$;
create function pg_temp.st(p_acc uuid, p_at timestamptz, p_key text) returns text language sql as $$
  select billing.account_state(p_acc, p_at)->>p_key
$$;
create function pg_temp.pp(p_acc uuid, p_at timestamptz, p_plant bigint, p_key text) returns text language sql as $$
  select e->>p_key from jsonb_array_elements(billing.account_state(p_acc, p_at)->'plants') e where (e->>'plant')::bigint = p_plant
$$;
create function pg_temp.ps(p_plant bigint, p_at timestamptz, p_key text) returns text language sql as $$
  select billing.plant_state(p_plant, p_at)->>p_key
$$;

-- ---------------------------------------------------------------------------
-- S1 free week, then pay
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s1'); r jsonb;
begin
  perform pg_temp.link(a, 's1', '{990000101,990000102,990000103}', pg_temp.t(0));
  perform pg_temp.eq('S1 linked, nothing chosen: none', pg_temp.st(a, pg_temp.t(0), 'state'), 'none');
  perform pg_temp.eq('S1 none may choose', pg_temp.st(a, pg_temp.t(0), 'may_choose'), 'true');
  perform pg_temp.eq('S1 fit-all plan for 3 plants', pg_temp.st(a, pg_temp.t(0), 'fit_all_plan'), 'family');
  perform pg_temp.fails('S1 an empty choice does not start the week',
    format('select billing.set_chosen_plants(%L, ''{}'', %L)', a, pg_temp.t(0)), 'at least one plant');

  r := pg_temp.choose(a, '{990000101,990000102}', pg_temp.t(0));
  perform pg_temp.eq('S1 choosing starts the week', r->>'state', 'trialing');
  perform pg_temp.eqt('S1 week ends day 7', r->>'trial_ends_at', pg_temp.t(7));
  perform pg_temp.eq('S1 week places', r->>'places', '5');
  perform pg_temp.eq('S1 chosen 2', r->>'chosen', '2');
  perform pg_temp.eq('S1 linked 3', r->>'linked', '3');
  perform pg_temp.eq('S1 open 3', r->>'open', '3');
  perform pg_temp.eq('S1 chosen plant read', pg_temp.pp(a, pg_temp.t(1), 990000101, 'read_now'), 'true');
  perform pg_temp.eq('S1 other plant locked', pg_temp.pp(a, pg_temp.t(1), 990000103, 'locked'), 'true');
  perform pg_temp.eq('S1 locked plant not read', pg_temp.pp(a, pg_temp.t(1), 990000103, 'read_now'), 'false');
  perform pg_temp.eq('S1 poller: chosen plant read', pg_temp.ps(990000101, pg_temp.t(1), 'read_now'), 'true');
  perform pg_temp.eq('S1 poller: locked plant not read', pg_temp.ps(990000103, pg_temp.t(1), 'read_now'), 'false');
  perform pg_temp.ok('S1 only seated plants used their week',
    (select count(*) = 2 and bool_and(trial_used_by = a) from billing.plants where id in (990000101, 990000102) and trial_used_at = pg_temp.t(0))
    and (select trial_used_at is null from billing.plants where id = 990000103));
  perform pg_temp.eq('S1 one login in the week', pg_temp.st(a, pg_temp.t(1), 'may_add_login'), 'false');
  perform pg_temp.fails('S1 second login refused in the week',
    format('select billing.link_login(%L, ''sunsynk'', ''s1b'', null, ''[{"id":990000109}]'', %L)', a, pg_temp.t(1)), 'one login');

  r := pg_temp.choose(a, '{990000101,990000103}', pg_temp.t(1));
  perform pg_temp.eq('S1 switch inside the week', r->>'chosen', '2');
  perform pg_temp.eq('S1 switched-out plant locked', pg_temp.pp(a, pg_temp.t(1), 990000102, 'locked'), 'true');
  perform pg_temp.ok('S1 switch logged', (select count(*) = 2 from billing.account_events where account = a and kind = 'set_chosen_plants'));

  perform pg_temp.pay(a, 'home', 'month', pg_temp.t(3));
  r := billing.account_state(a, pg_temp.t(3));
  perform pg_temp.eq('S1 paid: active', r->>'state', 'active');
  perform pg_temp.eq('S1 paid: plan', r->>'plan', 'home');
  perform pg_temp.eq('S1 paid: price', r->>'amount_minor', '9900');
  perform pg_temp.eq('S1 paid: places', r->>'places', '2');
  perform pg_temp.eqt('S1 paying ends the week', r->>'trial_ends_at', pg_temp.t(3));
  perform pg_temp.eqt('S1 next charge', r->>'next_charge_at', pg_temp.t(3) + interval '1 month');
  perform pg_temp.eq('S1 paid may add login', r->>'may_add_login', 'true');
  perform pg_temp.eq('S1 paid may not delete', r->>'may_delete', 'false');
  perform pg_temp.fails('S1 Home holds 2 plants',
    format('select billing.set_chosen_plants(%L, ''{990000101,990000102,990000103}'', %L)', a, pg_temp.t(4)), '2 places');
  perform pg_temp.eq('S1 still trialing at day 2 (clock moved back)', pg_temp.st(a, pg_temp.t(2), 'state'), 'trialing');
  perform pg_temp.eq('S1 renewal unpaid by its date: past_due', pg_temp.st(a, pg_temp.t(4) + interval '1 month', 'state'), 'past_due');
end $$;

-- ---------------------------------------------------------------------------
-- S2 week ends unpaid
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s2'); r jsonb;
begin
  perform pg_temp.link(a, 's2', '{990000201,990000202}', pg_temp.t(0));
  perform pg_temp.choose(a, '{990000201}', pg_temp.t(0));
  perform pg_temp.eq('S2 day 6.9 still trialing', pg_temp.st(a, pg_temp.t(6.9), 'state'), 'trialing');
  r := billing.account_state(a, pg_temp.t(7));
  perform pg_temp.eq('S2 day 7: ended', r->>'state', 'ended');
  perform pg_temp.eqt('S2 access ended day 7', r->>'access_ended_at', pg_temp.t(7));
  perform pg_temp.eq('S2 places 0', r->>'places', '0');
  perform pg_temp.eq('S2 choice kept', r->>'chosen', '1');
  perform pg_temp.eq('S2 no login added', r->>'may_add_login', 'false');
  perform pg_temp.eq('S2 no choosing', r->>'may_choose', 'false');
  perform pg_temp.eq('S2 may delete', r->>'may_delete', 'true');
  perform pg_temp.eq('S2 reading stops', pg_temp.pp(a, pg_temp.t(7), 990000201, 'read_now'), 'false');
  perform pg_temp.eqt('S2 history kept to day 37', pg_temp.pp(a, pg_temp.t(7), 990000201, 'delete_at'), pg_temp.t(37));
  perform pg_temp.eq('S2 poller stops', pg_temp.ps(990000201, pg_temp.t(7), 'read_now'), 'false');
  perform pg_temp.eqt('S2 never-chosen plant: delete now', pg_temp.ps(990000202, pg_temp.t(8), 'delete_at'), pg_temp.t(8));
  perform pg_temp.fails('S2 choosing refused', format('select billing.set_chosen_plants(%L, ''{990000202}'', %L)', a, pg_temp.t(8)), 'ended');
  perform pg_temp.fails('S2 new login refused', format('select billing.link_login(%L, ''sunsynk'', ''s2b'', null, ''[]'', %L)', a, pg_temp.t(8)), 'without a plan');
  r := billing.link_login(a, 'sunsynk', 's2', null, '[{"id":990000201},{"id":990000202}]', pg_temp.t(8));
  perform pg_temp.eq('S2 reconnecting the same login allowed', r->>'state', 'ended');
  perform pg_temp.pay(a, 'home', 'month', pg_temp.t(20));
  perform pg_temp.eq('S2 one payment reads again', pg_temp.pp(a, pg_temp.t(20), 990000201, 'read_now'), 'true');
end $$;

-- ---------------------------------------------------------------------------
-- S3 removing the only login after the week
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s3'); l uuid; r jsonb;
begin
  l := pg_temp.link(a, 's3', '{990000301,990000302}', pg_temp.t(0));
  perform pg_temp.choose(a, '{990000301,990000302}', pg_temp.t(0));
  r := billing.remove_login(a, l, pg_temp.t(10));
  perform pg_temp.eq('S3 both plants lose protection', r->>'unprotected', '[990000301, 990000302]');
  perform pg_temp.eq('S3 still ended (week used)', r->>'state', 'ended');
  perform pg_temp.eq('S3 nothing linked', r->>'linked', '0');
  perform pg_temp.eq('S3 nothing chosen', r->>'chosen', '0');
  perform pg_temp.eqt('S3 history deleted at once', pg_temp.ps(990000301, pg_temp.t(10), 'delete_at'), pg_temp.t(10));
  perform pg_temp.ok('S3 seats closed as login_removed',
    (select count(*) = 2 from billing.seats where account = a and close_reason = 'login_removed' and closed_at = pg_temp.t(10)));
  perform pg_temp.fails('S3 no new login without a plan',
    format('select billing.link_login(%L, ''sunsynk'', ''s3'', null, ''[{"id":990000301}]'', %L)', a, pg_temp.t(11)), 'without a plan');
end $$;

-- ---------------------------------------------------------------------------
-- S4 two accounts share a plant, one paid one not; a share claim reads too
-- ---------------------------------------------------------------------------
do $$
declare a1 uuid := pg_temp.acct('s4a'); a2 uuid := pg_temp.acct('s4b'); a3 uuid := pg_temp.acct('s4c'); s uuid;
begin
  perform pg_temp.link(a2, 's4b', '{990000401}', pg_temp.t(0));
  perform pg_temp.choose(a2, '{990000401}', pg_temp.t(0));
  perform pg_temp.link(a1, 's4a', '{990000401}', pg_temp.t(0));
  perform pg_temp.eq('S4 week used by the other account: pay screen', pg_temp.st(a1, pg_temp.t(0), 'state'), 'ended');
  s := pg_temp.pay(a1, 'home', 'month', pg_temp.t(1));
  perform pg_temp.choose(a1, '{990000401}', pg_temp.t(1));
  perform pg_temp.eq('S4 plant read for the payer', pg_temp.pp(a1, pg_temp.t(8), 990000401, 'read_now'), 'true');
  perform pg_temp.eq('S4 not read for the unpaid one', pg_temp.pp(a2, pg_temp.t(8), 990000401, 'read_now'), 'false');
  perform pg_temp.eq('S4 unpaid one: no kept-until, the payer keeps it', pg_temp.pp(a2, pg_temp.t(8), 990000401, 'delete_at'), null);
  perform pg_temp.eq('S4 poller reads it', pg_temp.ps(990000401, pg_temp.t(8), 'read_now'), 'true');
  perform pg_temp.eq('S4 protected', pg_temp.ps(990000401, pg_temp.t(8), 'protected'), 'true');
  update billing.subscriptions set cancel_at_period_end = true where id = s;
  perform pg_temp.eqt('S4 both ended: latest end + 30 days', pg_temp.ps(990000401, pg_temp.t(40), 'delete_at'),
                      pg_temp.t(1) + interval '1 month' + interval '30 days');

  insert into billing.plants (id, brand, external_id) values (990000403, 'sunsynk', '990000403');
  insert into billing.plant_claims (plant, account, claimed_at) values (990000403, a3, pg_temp.t(0));
  perform pg_temp.choose(a3, '{990000403}', pg_temp.t(0));
  perform pg_temp.eq('S4 share claim is a route', pg_temp.pp(a3, pg_temp.t(1), 990000403, 'read_now'), 'true');
end $$;

-- ---------------------------------------------------------------------------
-- S5 two logins reach the same plant
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s5'); l1 uuid; l2 uuid; r jsonb;
begin
  l1 := pg_temp.link(a, 's5a', '{990000501,990000502}', pg_temp.t(0));
  perform pg_temp.pay(a, 'family', 'month', pg_temp.t(0));
  l2 := pg_temp.link(a, 's5b', '{990000502,990000503}', pg_temp.t(0));
  perform pg_temp.ok('S5 plant on two logins: two rows', (select count(*) = 2 from billing.login_plants where plant = 990000502));
  r := pg_temp.choose(a, '{990000501,990000502,990000503}', pg_temp.t(1));
  perform pg_temp.eq('S5 linked counts the plant once', r->>'linked', '3');
  perform pg_temp.ok('S5 one seat', (select count(*) = 1 from billing.seats where plant = 990000502 and closed_at is null));
  r := billing.remove_login(a, l1, pg_temp.t(2));
  perform pg_temp.eq('S5 only the plant with no other route loses its seat', r->>'unprotected', '[990000501]');
  perform pg_temp.eq('S5 shared plant still read', pg_temp.pp(a, pg_temp.t(2), 990000502, 'read_now'), 'true');
  perform pg_temp.eq('S5 chosen 2', r->>'chosen', '2');
end $$;

-- ---------------------------------------------------------------------------
-- S6 a login needs reconnecting
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s6'); l uuid;
begin
  l := pg_temp.link(a, 's6', '{990000601}', pg_temp.t(0));
  perform pg_temp.choose(a, '{990000601}', pg_temp.t(0));
  update billing.logins set status = 'needs_reconnect' where id = l;
  perform pg_temp.eq('S6 broken login: not read', pg_temp.pp(a, pg_temp.t(1), 990000601, 'read_now'), 'false');
  perform pg_temp.eq('S6 needs reconnect', pg_temp.pp(a, pg_temp.t(1), 990000601, 'needs_reconnect'), 'true');
  perform pg_temp.eq('S6 history kept', pg_temp.ps(990000601, pg_temp.t(1), 'protected'), 'true');
  perform pg_temp.eq('S6 no delete date', pg_temp.ps(990000601, pg_temp.t(1), 'delete_at'), null);
  perform pg_temp.eq('S6 still chosen', pg_temp.pp(a, pg_temp.t(1), 990000601, 'chosen'), 'true');
  perform billing.link_login(a, 'sunsynk', 's6', gen_random_uuid(), '[{"id":990000601}]', pg_temp.t(2));
  perform pg_temp.eq('S6 reconnected: read again', pg_temp.pp(a, pg_temp.t(2), 990000601, 'read_now'), 'true');
  perform pg_temp.eq('S6 reconnected: flag gone', pg_temp.pp(a, pg_temp.t(2), 990000601, 'needs_reconnect'), 'false');
end $$;

-- ---------------------------------------------------------------------------
-- S7 failed card through day 15; paying inside the window
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s7'); b uuid := pg_temp.acct('s7b'); s uuid; p timestamptz := pg_temp.t(0) + interval '1 month'; r jsonb;
begin
  s := pg_temp.pay(a, 'home', 'month', pg_temp.t(0));
  perform pg_temp.link(a, 's7', '{990000701}', pg_temp.t(0));
  perform pg_temp.choose(a, '{990000701}', pg_temp.t(0));
  perform pg_temp.eqt('S7 next charge on the due date', pg_temp.st(a, p - interval '1 hour', 'next_charge_at'), p);
  r := billing.account_state(a, p + interval '1 day');
  perform pg_temp.eq('S7 day 1: past_due', r->>'state', 'past_due');
  perform pg_temp.eqt('S7 day 0 is the due date', r->>'past_due_since', p);
  perform pg_temp.eqt('S7 next retry day 3', r->>'next_retry_at', p + interval '3 days');
  perform pg_temp.eqt('S7 plan ends day 15', r->>'plan_ends_at', p + interval '15 days');
  perform pg_temp.eq('S7 reading goes on', pg_temp.pp(a, p + interval '1 day', 990000701, 'read_now'), 'true');
  perform pg_temp.eq('S7 no switching', r->>'may_switch', 'false');
  perform pg_temp.fails('S7 choosing refused while past_due',
    format('select billing.set_chosen_plants(%L, ''{}'', %L)', a, p + interval '1 day'), 'past_due');
  perform pg_temp.eqt('S7 day 8: next retry day 14', pg_temp.st(a, p + interval '8 days', 'next_retry_at'), p + interval '14 days');
  perform pg_temp.eq('S7 day 14.5: still past_due', pg_temp.st(a, p + interval '14 days 12 hours', 'state'), 'past_due');
  perform pg_temp.eq('S7 day 14.5: no retries left', pg_temp.st(a, p + interval '14 days 12 hours', 'next_retry_at'), null);
  r := billing.account_state(a, p + interval '15 days');
  perform pg_temp.eq('S7 day 15: ended', r->>'state', 'ended');
  perform pg_temp.eqt('S7 ended on day 15', r->>'access_ended_at', p + interval '15 days');
  perform pg_temp.eq('S7 day 15: not read', pg_temp.pp(a, p + interval '15 days', 990000701, 'read_now'), 'false');
  perform pg_temp.eqt('S7 history kept 30 days', pg_temp.pp(a, p + interval '15 days', 990000701, 'delete_at'), p + interval '45 days');
  -- the job wrote past_due: same answers
  update billing.subscriptions set status = 'past_due', past_due_since = p where id = s;
  perform pg_temp.eqt('S7 stored past_due: same retry', pg_temp.st(a, p + interval '4 days', 'next_retry_at'), p + interval '7 days');
  perform pg_temp.eq('S7 stored past_due: day 15 ended', pg_temp.st(a, p + interval '15 days', 'state'), 'ended');
  -- paid on day 10: same billing day, next period
  update billing.subscriptions set status = 'active', past_due_since = null, period_start = p, period_end = p + interval '1 month' where id = s;
  r := billing.account_state(a, p + interval '10 days');
  perform pg_temp.eq('S7 paid on day 10: active', r->>'state', 'active');
  perform pg_temp.eqt('S7 billing date kept', r->>'next_charge_at', p + interval '1 month');
  perform pg_temp.eq('S7 paid: read', pg_temp.pp(a, p + interval '10 days', 990000701, 'read_now'), 'true');
  -- yearly price copied
  perform pg_temp.pay(b, 'family', 'year', pg_temp.t(0));
  perform pg_temp.eq('S7 yearly = 10 months', pg_temp.st(b, pg_temp.t(1), 'amount_minor'), '199000');
end $$;

-- ---------------------------------------------------------------------------
-- S8 cancel
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s8'); s uuid; e timestamptz := pg_temp.t(0) + interval '1 month'; r jsonb;
begin
  s := pg_temp.pay(a, 'home', 'month', pg_temp.t(0));
  perform pg_temp.link(a, 's8', '{990000801}', pg_temp.t(0));
  perform pg_temp.choose(a, '{990000801}', pg_temp.t(0));
  update billing.subscriptions set cancel_at_period_end = true where id = s;
  r := billing.account_state(a, pg_temp.t(10));
  perform pg_temp.eq('S8 cancel booked: still active', r->>'state', 'active');
  perform pg_temp.eqt('S8 cancel date', r->>'cancel_at', e);
  perform pg_temp.eq('S8 no next charge', r->>'next_charge_at', null);
  perform pg_temp.eq('S8 may not delete yet', r->>'may_delete', 'false');
  r := billing.account_state(a, e);
  perform pg_temp.eq('S8 cancel date reached: ended (no job ran)', r->>'state', 'ended');
  perform pg_temp.eqt('S8 ended on the cancel date', r->>'access_ended_at', e);
  perform pg_temp.eqt('S8 history kept 30 days', pg_temp.pp(a, e, 990000801, 'delete_at'), e + interval '30 days');
  perform pg_temp.eq('S8 may delete', r->>'may_delete', 'true');
end $$;

-- ---------------------------------------------------------------------------
-- S9 upgrade and downgrade; must_choose after a shrink
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s9'); s uuid; r jsonb;
begin
  perform pg_temp.link(a, 's9', '{990000901,990000902,990000903,990000904}', pg_temp.t(0));
  s := pg_temp.pay(a, 'home', 'month', pg_temp.t(0), 'launch');
  perform pg_temp.eq('S9 launch price', pg_temp.st(a, pg_temp.t(0), 'amount_minor'), '4900');
  perform pg_temp.choose(a, '{990000901,990000902}', pg_temp.t(0));
  perform pg_temp.fails('S9 Home: third plant refused',
    format('select billing.set_chosen_plants(%L, ''{990000901,990000902,990000903}'', %L)', a, pg_temp.t(1)), '2 places');
  update billing.subscriptions set plan = 'family', amount_minor = 9900 where id = s;   -- upgrade (phase 3 command)
  r := pg_temp.choose(a, '{990000901,990000902,990000903,990000904}', pg_temp.t(2));
  perform pg_temp.eq('S9 Family: 5 places', r->>'places', '5');
  perform pg_temp.eq('S9 Family: 4 chosen', r->>'chosen', '4');
  perform pg_temp.eq('S9 offer kept on upgrade', (select offer from billing.subscriptions where id = s), 'launch');
  update billing.subscriptions set plan = 'home', amount_minor = 4900 where id = s;     -- downgrade applied
  r := billing.account_state(a, pg_temp.t(3));
  perform pg_temp.eq('S9 over places: must choose', r->>'must_choose', 'true');
  perform pg_temp.eq('S9 must choose: nothing read', pg_temp.ps(990000901, pg_temp.t(3), 'read_now'), 'false');
  perform pg_temp.eq('S9 must choose: history kept', pg_temp.ps(990000901, pg_temp.t(3), 'protected'), 'true');
  perform pg_temp.eq('S9 must choose: may choose', r->>'may_choose', 'true');
  r := pg_temp.choose(a, '{990000901,990000902}', pg_temp.t(3));
  perform pg_temp.eq('S9 picked: must choose cleared', r->>'must_choose', 'false');
  perform pg_temp.eq('S9 picked: read again', pg_temp.pp(a, pg_temp.t(3), 990000901, 'read_now'), 'true');
  perform pg_temp.eqt('S9 dropped plant: no other holder, delete now', pg_temp.ps(990000904, pg_temp.t(3), 'delete_at'), pg_temp.t(3));
end $$;

-- ---------------------------------------------------------------------------
-- S10 a plant whose week was used elsewhere
-- ---------------------------------------------------------------------------
do $$
declare a1 uuid := pg_temp.acct('s10a'); a2 uuid := pg_temp.acct('s10b'); l uuid; r jsonb;
begin
  perform pg_temp.link(a1, 's10a', '{990001001,990001003}', pg_temp.t(0));
  perform pg_temp.choose(a1, '{990001001}', pg_temp.t(0));
  l := pg_temp.link(a2, 's10b', '{990001001}', pg_temp.t(1));
  perform pg_temp.eq('S10 only used plants: pay screen', pg_temp.st(a2, pg_temp.t(1), 'state'), 'ended');
  perform pg_temp.eq('S10 marked used elsewhere', pg_temp.pp(a2, pg_temp.t(1), 990001001, 'trial_used_elsewhere'), 'true');
  perform pg_temp.fails('S10 used plant cannot start a week',
    format('select billing.set_chosen_plants(%L, ''{990001001}'', %L)', a2, pg_temp.t(1)), 'cannot be chosen');
  r := billing.remove_login(a2, l, pg_temp.t(1));
  perform pg_temp.eq('S10 no login, no week: none (not stuck)', r->>'state', 'none');
  perform pg_temp.link(a2, 's10c', '{990001001,990001002}', pg_temp.t(1));
  perform pg_temp.eq('S10 an unused plant: none', pg_temp.st(a2, pg_temp.t(1), 'state'), 'none');
  perform pg_temp.fails('S10 used plant refused in the week',
    format('select billing.set_chosen_plants(%L, ''{990001001,990001002}'', %L)', a2, pg_temp.t(1)), 'already had its free week');
  r := pg_temp.choose(a2, '{990001002}', pg_temp.t(1));
  perform pg_temp.eq('S10 unused plant starts the week', r->>'state', 'trialing');
  r := pg_temp.choose(a1, '{990001003}', pg_temp.t(2));
  r := pg_temp.choose(a1, '{990001001}', pg_temp.t(3));
  perform pg_temp.eq('S10 switching back to its own week''s plant works', r->>'chosen', '1');
end $$;

-- ---------------------------------------------------------------------------
-- S11 more than 5 plants in the week
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s11'); r jsonb;
begin
  perform pg_temp.link(a, 's11', '{990001101,990001102,990001103,990001104,990001105,990001106,990001107}', pg_temp.t(0));
  perform pg_temp.eq('S11 7 linked', pg_temp.st(a, pg_temp.t(0), 'linked'), '7');
  perform pg_temp.eq('S11 no plan fits 7', pg_temp.st(a, pg_temp.t(0), 'fit_all_plan'), null);
  perform pg_temp.fails('S11 6 refused',
    format('select billing.set_chosen_plants(%L, ''{990001101,990001102,990001103,990001104,990001105,990001106}'', %L)', a, pg_temp.t(0)), 'up to 5');
  perform pg_temp.eq('S11 refusal starts nothing', pg_temp.st(a, pg_temp.t(0), 'state'), 'none');
  r := pg_temp.choose(a, '{990001101,990001102,990001103,990001104,990001105}', pg_temp.t(0));
  perform pg_temp.eq('S11 5 chosen', r->>'chosen', '5');
  perform pg_temp.eq('S11 sixth locked', pg_temp.pp(a, pg_temp.t(0), 990001106, 'locked'), 'true');
  perform pg_temp.ok('S11 unchosen plants keep their week', (select trial_used_at is null from billing.plants where id = 990001106));
end $$;

-- ---------------------------------------------------------------------------
-- S12 must_choose after a grant ends; grant-only account
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s12'); b uuid := pg_temp.acct('s12b'); r jsonb;
begin
  perform pg_temp.link(a, 's12', '{990001201,990001202,990001203}', pg_temp.t(0));
  perform pg_temp.pay(a, 'home', 'month', pg_temp.t(0));
  insert into billing.grants (account, places, reason, starts_at, ends_at) values (a, 1, 'support', pg_temp.t(0), pg_temp.t(10));
  r := pg_temp.choose(a, '{990001201,990001202,990001203}', pg_temp.t(1));
  perform pg_temp.eq('S12 plan + grant places', r->>'places', '3');
  r := billing.account_state(a, pg_temp.t(10));
  perform pg_temp.eq('S12 grant ended: places 2', r->>'places', '2');
  perform pg_temp.eq('S12 grant ended: must choose', r->>'must_choose', 'true');
  perform pg_temp.eq('S12 must choose: not read', pg_temp.pp(a, pg_temp.t(10), 990001201, 'read_now'), 'false');
  perform pg_temp.eq('S12 must choose: kept', pg_temp.pp(a, pg_temp.t(10), 990001201, 'delete_at'), null);
  insert into billing.grants (account, places, reason, starts_at) values (b, 2, 'comped', pg_temp.t(0));
  r := billing.account_state(b, pg_temp.t(5));
  perform pg_temp.eq('S12 grant only: active', r->>'state', 'active');
  perform pg_temp.eq('S12 grant only: places', r->>'places', '2');
  perform pg_temp.eq('S12 grant only: no charge', r->>'next_charge_at', null);
end $$;

-- ---------------------------------------------------------------------------
-- S13 database rules: offer on restart, one live plan, version
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s13'); s uuid; v bigint;
begin
  s := pg_temp.pay(a, 'home', 'month', pg_temp.t(0), 'launch');
  perform pg_temp.fails('S13 one live plan per account',
    format('select pg_temp.pay(%L, ''family'', ''month'', %L)', a, pg_temp.t(1)), 'subscriptions_one_live');
  update billing.subscriptions set status = 'ended', ended_at = pg_temp.t(5) where id = s;
  perform pg_temp.fails('S13 launch price refused on a restart',
    format('select pg_temp.pay(%L, ''home'', ''month'', %L, ''launch'')', a, pg_temp.t(6)), 'first-time');
  perform pg_temp.pay(a, 'home', 'month', pg_temp.t(6));
  perform pg_temp.eq('S13 restart pays list price', pg_temp.st(a, pg_temp.t(6), 'amount_minor'), '9900');
  v := (select version from billing.accounts where id = a);
  perform pg_temp.link(a, 's13', '{990001301}', pg_temp.t(6));
  perform pg_temp.ok('S13 a command bumps the version', (select version = v + 1 from billing.accounts where id = a));
  perform pg_temp.ok('S13 a command is logged', exists (select 1 from billing.account_events where account = a and kind = 'link_login'));
  perform pg_temp.fails('S13 a plant not on the account cannot be chosen',
    format('select billing.set_chosen_plants(%L, ''{990000101}'', %L)', a, pg_temp.t(6)), 'not on this account');
end $$;

-- ---------------------------------------------------------------------------
-- S14 copying today's tables
-- ---------------------------------------------------------------------------
do $$
declare
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); lg uuid := gen_random_uuid(); sec uuid := gen_random_uuid();
  a1 uuid; a2 uuid; r jsonb;
begin
  set local session_replication_role = replica;   -- old tables' triggers off while making rows
  insert into auth.users (id, email, created_at) values (u1, 'copy1@state.test', '2026-11-10'), (u2, 'copy2@state.test', '2026-11-10');
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, refresh_secret_id, status, kind)
  values (lg, u1, 'copy1', sec, 'active', 'login');
  insert into public.plant_users (plant_id, user_id, account_id, plant_name, paused) values
    (990001401, u1, lg, 'House', false), (990001402, u1, lg, 'Flat', false), (990001403, u1, lg, 'Shed', true);
  insert into private.plant_picks (user_id, plant_id, held, picked_at) values
    (u1, 990001401, false, '2026-11-10 12:00+02'), (u1, 990001402, true, '2026-11-10 12:00+02'), (u1, 990001403, false, '2026-11-10 12:00+02');
  insert into private.free_week_logins (sunsynk_username, user_id, started_at, over_at, over_why)
  values ('copy1', u1, '2026-11-10 12:00+02', '2026-11-12 09:00+02', 'plan');
  insert into private.plant_week (plant_id, started_at) values (990001401, '2026-11-10 12:00+02');
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, created_at, offer_id)
  values (u1, 'home', 'monthly', 12, '2026-12-12', 'active', '2026-11-12 09:00+02', 'launch');
  insert into public.plant_users (plant_id, user_id, plant_name, via_share) values (990001404, u2, 'Farm', true);
  insert into private.plant_picks (user_id, plant_id, held, picked_at) values (u2, 990001404, false, '2026-11-10 12:00+02');
  insert into private.billing (user_id, plan, comped, created_at) values (u2, 'family', true, '2026-11-10');
  set local session_replication_role = origin;

  perform billing.copy_from_old();
  a1 := (select id from billing.accounts where user_id = u1);
  a2 := (select id from billing.accounts where user_id = u2);
  perform pg_temp.ok('S14 login keeps its id and vault id', exists (select 1 from billing.logins where id = lg and account = a1 and secret_ref = sec and status = 'ok'));
  perform pg_temp.ok('S14 three login plants', (select count(*) = 3 from billing.login_plants where login = lg));
  perform pg_temp.ok('S14 seat only for the pick not held and not paused',
    (select array_agg(plant) = '{990001401}' from billing.seats where account = a1 and closed_at is null));
  perform pg_temp.ok('S14 week from free_week_logins',
    (select trial_started_at = '2026-11-10 12:00+02' and trial_ends_at = '2026-11-12 09:00+02' from billing.accounts where id = a1));
  perform pg_temp.ok('S14 plant week used by the account', (select trial_used_by = a1 from billing.plants where id = 990001401));
  perform pg_temp.ok('S14 subscription copied',
    exists (select 1 from billing.subscriptions where account = a1 and plan = 'home' and interval = 'month' and amount_minor = 4900
              and offer = 'launch' and status = 'active' and billing_day = 12 and period_end = '2026-12-12 00:00+02'));
  r := billing.account_state(a1, '2026-11-22 12:00+02');
  perform pg_temp.eq('S14 state active', r->>'state', 'active');
  perform pg_temp.eq('S14 places 2', r->>'places', '2');
  perform pg_temp.eq('S14 chosen 1', r->>'chosen', '1');
  perform pg_temp.eqt('S14 next charge', r->>'next_charge_at', '2026-12-12 00:00+02');
  perform pg_temp.ok('S14 share claim copied', exists (select 1 from billing.plant_claims where plant = 990001404 and account = a2));
  perform pg_temp.eq('S14 comped: grant of 5', pg_temp.st(a2, '2026-11-22 12:00+02', 'places'), '5');
  perform pg_temp.eq('S14 shared plant read', pg_temp.pp(a2, '2026-11-22 12:00+02', 990001404, 'read_now'), 'true');
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r record; f int; n int;
begin
  for r in select * from t_results where not pass order by n loop
    raise warning 'FAIL  %  (%)', r.label, r.detail;
  end loop;
  select count(*) filter (where not pass), count(*) into f, n from t_results;
  raise notice '% checks, % failed', n, f;
  if f > 0 then raise exception 'billing state test failed'; end if;
end $$;
