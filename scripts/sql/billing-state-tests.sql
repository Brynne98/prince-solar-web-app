-- SOLAR-641 state test: every walk-through in reports/billing-redesign-2026-11-22.md,
-- run against billing.account_state / plant_state with a moved clock (each call takes `at`).
-- Run by scripts/billing-state-test.mjs inside one transaction that is rolled back.
-- S1-S13 write subscription rows directly (pg_temp.pay) to walk the states; the P
-- blocks after S14 go through the real payment commands and the daily job.

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
-- Lookups return '<no plant>' / '<no key>' instead of null when the row or key is
-- missing, so a check that wants null proves the value is really null.
create function pg_temp.key(p_obj jsonb, p_key text) returns text language sql as $$
  select case when p_obj is null then '<no plant>' when not p_obj ? p_key then '<no key>' else p_obj->>p_key end
$$;
create function pg_temp.st(p_acc uuid, p_at timestamptz, p_key text) returns text language sql as $$
  select pg_temp.key(billing.account_state(p_acc, p_at), p_key)
$$;
create function pg_temp.pp(p_acc uuid, p_at timestamptz, p_plant bigint, p_key text) returns text language sql as $$
  select pg_temp.key((select e from jsonb_array_elements(billing.account_state(p_acc, p_at)->'plants') e
                       where (e->>'plant')::bigint = p_plant), p_key)
$$;
create function pg_temp.ps(p_plant bigint, p_at timestamptz, p_key text) returns text language sql as $$
  select pg_temp.key(billing.plant_state(p_plant, p_at), p_key)
$$;
-- Stands in for the daily job (phase 2): records the first failed renewal try.
create function pg_temp.fail_renewal(p_sub uuid, p_at timestamptz) returns void language sql as $$
  update billing.subscriptions set status = 'past_due', past_due_since = p_at where id = p_sub
$$;

-- ---------------------------------------------------------------------------
-- S1 free week, then pay
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s1'); r jsonb; s uuid;
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

  s := pg_temp.pay(a, 'home', 'month', pg_temp.t(3));
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
  perform pg_temp.eq('S1 renewal due, no try recorded: still active', pg_temp.st(a, pg_temp.t(4) + interval '1 month', 'state'), 'active');
  perform pg_temp.fail_renewal(s, pg_temp.t(3) + interval '1 month');
  perform pg_temp.eq('S1 failed try recorded: past_due', pg_temp.st(a, pg_temp.t(4) + interval '1 month', 'state'), 'past_due');
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
  perform pg_temp.eq('S7 due, not tried: active', pg_temp.st(a, p + interval '1 day', 'state'), 'active');
  perform pg_temp.eq('S7 due, not tried: no past_due_since', pg_temp.st(a, p + interval '1 day', 'past_due_since'), null);
  perform pg_temp.fails('S7 past_due_since only with past_due',
    format('update billing.subscriptions set past_due_since = %L where id = %L', p, s), 'subscriptions_check');
  perform pg_temp.fail_renewal(s, p);
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
  perform pg_temp.eqt('S7 day 4: next retry day 7', pg_temp.st(a, p + interval '4 days', 'next_retry_at'), p + interval '7 days');
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
  -- a seat on an account with no known end date: no delete date, never "now"
  insert into billing.plants (id, brand, external_id) values (990001209, 'sunsynk', '990001209');
  insert into billing.seats (account, plant, chosen_at) values (pg_temp.acct('s12c'), 990001209, pg_temp.t(0));
  perform pg_temp.eq('S12 open seat, no end date: delete_at null', pg_temp.ps(990001209, pg_temp.t(1), 'delete_at'), null);
end $$;

-- ---------------------------------------------------------------------------
-- S13 database rules: offer on restart, one live plan, version
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('s13'); b uuid; s uuid; v bigint;
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
  perform pg_temp.choose(a, '{990001301}', pg_temp.t(6));
  perform pg_temp.ok('S13 a seat on a paid plan uses the plant''s week',
    (select trial_used_at = pg_temp.t(6) and trial_used_by = a from billing.plants where id = 990001301));
  b := pg_temp.acct('s13b');
  perform pg_temp.link(b, 's13b', '{990001301}', pg_temp.t(7));
  perform pg_temp.eq('S13 a paid-for plant gives no free week', pg_temp.st(b, pg_temp.t(7), 'state'), 'ended');
  -- link_login bumps the version of plants whose route changed
  v := (select version from billing.plants where id = 990001301);
  perform billing.link_login(a, 'sunsynk', 's13', null, '[{"id":990001302}]', pg_temp.t(8));
  perform pg_temp.ok('S13 a plant gone from the login: version bumped', (select version = v + 1 from billing.plants where id = 990001301));
  perform billing.link_login(a, 'sunsynk', 's13', null, '[{"id":990001302}]', pg_temp.t(9));
  perform pg_temp.ok('S13 nothing changed: no bump', (select version = v + 1 from billing.plants where id = 990001301));
  perform billing.link_login(a, 'sunsynk', 's13', null, '[{"id":990001301},{"id":990001302}]', pg_temp.t(10));
  perform pg_temp.ok('S13 a plant back on the login: version bumped', (select version = v + 2 from billing.plants where id = 990001301));
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
    (u1, 990001401, true, '2026-11-10 12:00+02'), (u1, 990001402, false, '2026-11-10 12:00+02'), (u1, 990001403, true, '2026-11-10 12:00+02');
  insert into private.free_week_logins (sunsynk_username, user_id, started_at, over_at, over_why)
  values ('copy1', u1, '2026-11-10 12:00+02', '2026-11-12 09:00+02', 'plan');
  insert into private.plant_week (plant_id, started_at) values (990001401, '2026-11-10 12:00+02');
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, created_at, offer_id, card, card_email)
  values (u1, 'home', 'monthly', 12, '2026-12-12', 'active', '2026-11-12 09:00+02', 'launch',
          '{"authorization_code":"AUTH_copy1","last4":"4081","exp_month":"12","exp_year":"2030","reusable":true,"card_type":"visa"}', 'copy1@state.test');
  insert into public.plant_users (plant_id, user_id, plant_name, via_share) values (990001404, u2, 'Farm', true);
  insert into private.plant_picks (user_id, plant_id, held, picked_at) values (u2, 990001404, true, '2026-11-10 12:00+02');
  insert into private.billing (user_id, plan, comped, created_at) values (u2, 'family', true, '2026-11-10');
  set local session_replication_role = origin;

  perform billing.copy_from_old();
  a1 := (select id from billing.accounts where user_id = u1);
  a2 := (select id from billing.accounts where user_id = u2);
  perform pg_temp.ok('S14 login keeps its id and vault id', exists (select 1 from billing.logins where id = lg and account = a1 and secret_ref = sec and status = 'ok'));
  perform pg_temp.ok('S14 three login plants', (select count(*) = 3 from billing.login_plants where login = lg));
  perform pg_temp.ok('S14 seat only for the held pick that is not paused',
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
  perform pg_temp.ok('S14 saved card copied', exists (select 1 from billing.payment_methods
    where account = a1 and auth_ref = 'AUTH_copy1' and auth_email = 'copy1@state.test' and active and last4 = '4081'));
  perform pg_temp.ok('S14 share claim copied', exists (select 1 from billing.plant_claims where plant = 990001404 and account = a2));
  perform pg_temp.eq('S14 comped: grant of 5', pg_temp.st(a2, '2026-11-22 12:00+02', 'places'), '5');
  perform pg_temp.eq('S14 shared plant read', pg_temp.pp(a2, '2026-11-22 12:00+02', 990001404, 'read_now'), 'true');
  r := billing.copy_from_old();
  perform pg_temp.ok('S14 second run copies fresh, no duplicates',
    (select count(*) = 1 from billing.seats s join billing.accounts a on a.id = s.account where a.user_id = u1)
    and (select count(*) = 1 from billing.subscriptions s join billing.accounts a on a.id = s.account where a.user_id = u1));
end $$;

-- ===========================================================================
-- Phase 2: money paths, through the real commands. No network: Paystack's answers
-- are made here (pg_temp.tx_ok and pg_temp.answer) and handed to apply_payment.
-- Runs after S14, which empties the billing tables (copy_from_old refuses once
-- billing.invoices has rows).
-- ===========================================================================
create function pg_temp.tx_ok(p_ref text, p_card text default 'AUTH_main', p_amount bigint default null,
                              p_currency text default 'ZAR') returns jsonb language sql as $$
  select jsonb_build_object('status', 'success', 'reference', p_ref, 'currency', p_currency, 'gateway_response', 'Approved',
    'amount', coalesce(p_amount, (select amount_minor from billing.payment_attempts where reference = p_ref)),
    'authorization', jsonb_build_object('authorization_code', p_card, 'reusable', true, 'last4', right(p_card, 4),
                                        'exp_month', '12', 'exp_year', '2030', 'card_type', 'visa', 'signature', 'SIG_' || p_card),
    'customer', jsonb_build_object('email', 'owner@state.test', 'customer_code', 'CUS_' || p_card))
$$;
create function pg_temp.answer(p_ref text, p_how text, p_at timestamptz, p_card text default 'AUTH_main') returns jsonb language sql as $$
  select billing.apply_payment(p_ref, case p_how
    when 'ok' then pg_temp.tx_ok(p_ref, p_card)
    when 'fail' then jsonb_build_object('status', 'failed', 'reference', p_ref, 'gateway_response', 'Insufficient Funds')
    when 'hard' then jsonb_build_object('status', 'failed', 'reference', p_ref, 'gateway_response', 'Stolen card')
    when 'abandoned' then jsonb_build_object('status', 'abandoned', 'reference', p_ref)
    when 'pending' then jsonb_build_object('status', 'paused', 'reference', p_ref, 'authorization_url', 'https://checkout.test/' || p_ref)
    when 'unknown' then jsonb_build_object('status', 'unknown', 'message', 'timeout')
    when 'not_found' then jsonb_build_object('status', 'not_found') end, p_at)
$$;
-- start_checkout + a card page try + Paystack's success
create function pg_temp.buy(p_acc uuid, p_plan text, p_interval text, p_plants bigint[], p_at timestamptz,
                            p_card text default 'AUTH_main', p_extras int default 0) returns jsonb language plpgsql as $$
declare inv uuid; ref text;
begin
  inv := (billing.start_checkout(p_acc, p_plan, p_interval, p_extras, p_plants, p_at)->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', p_at)->>'reference';
  return pg_temp.answer(ref, 'ok', p_at, p_card);
end $$;
-- the daily job at p_at; answers this account's charge with p_how (null: left unanswered). Returns its reference.
create function pg_temp.job(p_acc uuid, p_at timestamptz, p_how text default null) returns text language plpgsql as $$
declare r jsonb; c jsonb; mine text;
begin
  r := billing.run(p_at);
  for c in select * from jsonb_array_elements(r->'charges') loop
    if (select account from billing.invoices where id = (c->>'invoice')::uuid) = p_acc then
      mine := c->>'reference';
      if p_how is not null then perform pg_temp.answer(mine, p_how, p_at); end if;
    end if;
  end loop;
  return mine;
end $$;
create function pg_temp.sub(p_acc uuid) returns billing.subscriptions language sql as $$
  select * from billing.subscriptions where account = p_acc order by started_at desc limit 1
$$;
create function pg_temp.tries(p_acc uuid) returns int language sql as $$
  select count(*)::int from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
   where i.account = p_acc and pa.status <> 'void'
$$;

-- ---------------------------------------------------------------------------
-- P1 first purchase on the card page; replays; webhook dedupe
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p1'); r jsonb; inv uuid; ref text; e jsonb; s billing.subscriptions;
begin
  perform pg_temp.link(a, 'p1', '{990010101,990010102,990010103}', pg_temp.t(0));
  perform pg_temp.fails('P1 checkout needs the plant choice',
    format('select billing.start_checkout(%L, ''home'', ''month'', 0, null, %L)', a, pg_temp.t(0)), 'choose the plants');
  perform pg_temp.fails('P1 checkout: Home holds 2',
    format('select billing.start_checkout(%L, ''home'', ''month'', 0, ''{990010101,990010102,990010103}'', %L)', a, pg_temp.t(0)), '2 places');
  r := billing.start_checkout(a, 'home', 'month', 0, '{990010101,990010102}', pg_temp.t(0));
  inv := (r->>'invoice')::uuid;
  perform pg_temp.eq('P1 first-time member: launch price', r->>'amount_minor', '4900');
  perform pg_temp.eq('P1 no saved card yet', r->>'saved_card', 'false');
  perform pg_temp.ok('P1 version and choice bound to the bill',
    (select expected_version = (select version from billing.accounts where id = a) and plants = '{990010101,990010102}'
       from billing.invoices where id = inv));
  perform pg_temp.eq('P1 checkout changes nothing yet', pg_temp.st(a, pg_temp.t(0), 'state'), 'none');
  perform pg_temp.fails('P1 saved card: none to charge',
    format('select billing.begin_attempt(%L, ''saved_card'', %L)', inv, pg_temp.t(0)), 'no saved card');
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(0))->>'reference';
  perform pg_temp.ok('P1 reference written before the charge', exists (select 1 from billing.payment_attempts
    where reference = ref and status = 'pending' and claimed_until = pg_temp.t(0) + interval '1 hour' and ref like 'psh\_%'));
  r := pg_temp.answer(ref, 'ok', pg_temp.t(0) + interval '2 minutes');
  perform pg_temp.eq('P1 paid: applied', r->>'action', 'applied');
  r := billing.account_state(a, pg_temp.t(1));
  perform pg_temp.eq('P1 active', r->>'state', 'active');
  perform pg_temp.eq('P1 Home', r->>'plan', 'home');
  perform pg_temp.eq('P1 chosen from the bill', r->>'chosen', '2');
  perform pg_temp.eq('P1 card saved', r->'card'->>'last4', 'main');
  perform pg_temp.eq('P1 next amount', r->>'next_amount_minor', '4900');
  s := pg_temp.sub(a);
  perform pg_temp.ok('P1 billing day and period from the payment',
    s.billing_day = 1 and s.period_start = pg_temp.t(0) + interval '2 minutes' and s.period_end = pg_temp.t(31) + interval '2 minutes' and s.offer = 'launch');
  perform pg_temp.ok('P1 bill paid, period frozen', exists (select 1 from billing.invoices where id = inv and status = 'paid'
    and subscription = s.id and period_end = s.period_end));
  perform pg_temp.ok('P1 seated plants used their week', (select count(*) = 2 from billing.plants where id in (990010101, 990010102) and trial_used_by = a));
  r := pg_temp.answer(ref, 'ok', pg_temp.t(0) + interval '3 minutes');
  perform pg_temp.eq('P1 the same answer again: nothing new', r->>'action', 'again');
  perform pg_temp.ok('P1 one plan', (select count(*) = 1 from billing.subscriptions where account = a));
  perform pg_temp.fails('P1 second checkout refused while a plan runs',
    format('select billing.start_checkout(%L, ''family'', ''month'', 0, ''{}'', %L)', a, pg_temp.t(1)), 'already running');
  -- webhook dedupe: (provider, type, entity, status)
  e := billing.event_begin('paystack', 'charge.success', ref, 'success', '{}', pg_temp.t(0));
  perform pg_temp.eq('P1 first webhook: process', e->>'process', 'true');
  e := billing.event_begin('paystack', 'charge.success', ref, 'success', '{}', pg_temp.t(0));
  perform pg_temp.eq('P1 crashed before done: process again', e->>'process', 'true');
  perform billing.event_done((e->>'id')::bigint, null, pg_temp.t(0));
  e := billing.event_begin('paystack', 'charge.success', ref, 'success', '{}', pg_temp.t(0));
  perform pg_temp.eq('P1 processed: duplicate stops', e->>'process', 'false');
  e := billing.event_begin('paystack', 'refund.processed', ref, 'processed', '{}', pg_temp.t(0));
  perform pg_temp.eq('P1 another status of the same entity: process', e->>'process', 'true');
end $$;

-- ---------------------------------------------------------------------------
-- P2 two tabs race a first purchase; a stale checkout; wrong amount; unknown reference
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p2'); b uuid := pg_temp.acct('p2b'); i1 uuid; i2 uuid; r1 text; r2 text; r jsonb; rf uuid;
begin
  perform pg_temp.link(a, 'p2', '{990010201,990010202}', pg_temp.t(0));
  i1 := (billing.start_checkout(a, 'home', 'month', 0, '{990010201}', pg_temp.t(0))->>'invoice')::uuid;
  i2 := (billing.start_checkout(a, 'family', 'month', 0, '{990010201,990010202}', pg_temp.t(0))->>'invoice')::uuid;
  r1 := billing.begin_attempt(i1, 'card_page', pg_temp.t(0))->>'reference';
  r2 := billing.begin_attempt(i2, 'card_page', pg_temp.t(0))->>'reference';
  r := pg_temp.answer(r2, 'ok', pg_temp.t(0) + interval '1 minute');
  perform pg_temp.eq('P2 first tab paid: applied', r->>'action', 'applied');
  r := pg_temp.answer(r1, 'ok', pg_temp.t(0) + interval '2 minutes');
  perform pg_temp.eq('P2 second tab: refunded', r->>'action', 'refund');
  perform pg_temp.eq('P2 second tab: stale', r->>'reason', 'stale');
  perform pg_temp.eq('P2 the first choice stands', pg_temp.st(a, pg_temp.t(1), 'plan'), 'family');
  perform pg_temp.ok('P2 one plan', (select count(*) = 1 from billing.subscriptions where account = a));
  perform pg_temp.ok('P2 refund owed against the try', exists (select 1 from billing.refunds r join billing.payment_attempts pa on pa.id = r.attempt
    where pa.reference = r1 and r.reason = 'stale' and r.status = 'due'));
  perform pg_temp.ok('P2 refunded try not counted as paid', (select status = 'not_applied' from billing.payment_attempts where reference = r1)
    and (select status = 'open' from billing.invoices where id = i1));
  -- two tries on one bill: the second success is a duplicate
  perform pg_temp.link(b, 'p2b', '{990010203}', pg_temp.t(0));
  i1 := (billing.start_checkout(b, 'home', 'month', 0, '{990010203}', pg_temp.t(0))->>'invoice')::uuid;
  r1 := billing.begin_attempt(i1, 'card_page', pg_temp.t(0))->>'reference';
  r2 := billing.begin_attempt(i1, 'card_page', pg_temp.t(0))->>'reference';
  perform pg_temp.answer(r1, 'ok', pg_temp.t(0));
  r := pg_temp.answer(r2, 'ok', pg_temp.t(0));
  perform pg_temp.eq('P2 same bill paid twice: duplicate refunded', r->>'reason', 'duplicate');
  perform pg_temp.ok('P2 at most one success per bill', (select count(*) = 1 from billing.payment_attempts where invoice = i1 and status = 'success'));
end $$;

do $$
declare a uuid := pg_temp.acct('p3'); inv uuid; ref text; r jsonb;
begin
  perform pg_temp.link(a, 'p3', '{990010301}', pg_temp.t(0));
  inv := (billing.start_checkout(a, 'home', 'month', 0, '{990010301}', pg_temp.t(0))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(0))->>'reference';
  perform billing.link_login(a, 'sunsynk', 'p3', null, '[{"id":990010301},{"id":990010302}]', pg_temp.t(0) + interval '5 minutes');
  r := pg_temp.answer(ref, 'ok', pg_temp.t(0) + interval '10 minutes');
  perform pg_temp.eq('P3 account changed after checkout: stale, refunded', r->>'reason', 'stale');
  perform pg_temp.eq('P3 nothing applied', pg_temp.st(a, pg_temp.t(1), 'state'), 'none');
  inv := (billing.start_checkout(a, 'home', 'month', 0, '{990010301}', pg_temp.t(1))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(1))->>'reference';
  r := billing.apply_payment(ref, pg_temp.tx_ok(ref, 'AUTH_main', 100), pg_temp.t(1));
  perform pg_temp.eq('P3 wrong amount: refunded', r->>'reason', 'wrong_amount');
  r := billing.apply_payment(ref, pg_temp.tx_ok(ref, 'AUTH_main', null, 'NGN'), pg_temp.t(1));
  perform pg_temp.eq('P3 refunded try: a later answer changes nothing', r->>'action', 'again');
  inv := (billing.start_checkout(a, 'home', 'month', 0, '{990010301}', pg_temp.t(1))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(1))->>'reference';
  r := billing.apply_payment(ref, pg_temp.tx_ok(ref, 'AUTH_main', null, 'NGN'), pg_temp.t(1));
  perform pg_temp.eq('P3 wrong currency: refunded', r->>'reason', 'wrong_amount');
  r := billing.apply_payment('psh_nobody', jsonb_build_object('status', 'success', 'reference', 'psh_nobody', 'amount', 4900, 'currency', 'ZAR'), pg_temp.t(1));
  perform pg_temp.eq('P3 our reference, no try held: refunded', r->>'reason', 'unknown_account');
  r := billing.apply_payment('other_ref', jsonb_build_object('status', 'success', 'reference', 'other_ref'), pg_temp.t(1));
  perform pg_temp.eq('P3 not our reference: ignored', r->>'action', 'ignored');
  -- an abandoned card page is not a decline and changes nothing
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(1))->>'reference';
  r := pg_temp.answer(ref, 'abandoned', pg_temp.t(1));
  perform pg_temp.eq('P3 abandoned page: not a decline', r->>'declined', 'false');
end $$;

-- ---------------------------------------------------------------------------
-- P4 renewal paid; the webhook and the job's charge reply on the same bill
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p4'); ref text; ref2 text; r jsonb; s billing.subscriptions; pe timestamptz; inv uuid;
begin
  perform pg_temp.link(a, 'p4', '{990010401}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990010401}', pg_temp.t(0));
  pe := (pg_temp.sub(a)).period_end;
  perform pg_temp.eq('P4 before the date: nothing to charge', pg_temp.job(a, pe - interval '1 hour'), null);
  ref := pg_temp.job(a, pe + interval '1 hour');
  perform pg_temp.ok('P4 the job wrote the try first', exists (select 1 from billing.payment_attempts
    where reference = ref and status = 'created' and channel = 'saved_card' and claimed_until = pe + interval '70 minutes'));
  inv := (select invoice from billing.payment_attempts where reference = ref);
  perform pg_temp.ok('P4 renewal bill frozen', exists (select 1 from billing.invoices where id = inv and kind = 'renewal'
    and amount_minor = 4900 and period_start = pe and period_end = pe + interval '1 month'));
  perform pg_temp.eq('P4 Pay while the job charges: busy', billing.begin_attempt(inv, 'saved_card', pe + interval '62 minutes')->>'busy', 'true');
  r := pg_temp.answer(ref, 'ok', pe + interval '61 minutes');          -- the webhook first
  perform pg_temp.eq('P4 webhook applies', r->>'action', 'applied');
  r := pg_temp.answer(ref, 'ok', pe + interval '62 minutes');          -- then the charge reply
  perform pg_temp.eq('P4 charge reply: again', r->>'action', 'again');
  s := pg_temp.sub(a);
  perform pg_temp.ok('P4 one period on, once', s.period_start = pe and s.period_end = pe + interval '1 month' and s.status = 'active');
  perform pg_temp.eq('P4 run again: nothing due', pg_temp.job(a, pe + interval '2 hours'), null);
  perform pg_temp.ok('P4 one bill for the period', (select count(*) = 1 from billing.invoices where subscription = s.id and kind = 'renewal'));
  -- a stale renewal try that pays after another try already paid the bill
  perform pg_temp.fails('P4 one renewal bill per period (database)',
    format('insert into billing.invoices (account, subscription, kind, plan, amount_minor, currency, period_key, created_at) select account, subscription, kind, plan, amount_minor, currency, period_key, created_at from billing.invoices where id = %L', inv),
    'invoices_one_per_period');
end $$;

-- ---------------------------------------------------------------------------
-- P5 failed card: retries on days 3, 7, 14 from the market row; ends day 15
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p5'); pe timestamptz; r jsonb; ref text;
begin
  perform pg_temp.link(a, 'p5', '{990010501}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990010501}', pg_temp.t(0));
  pe := (pg_temp.sub(a)).period_end;
  perform pg_temp.ok('P5 day 0 charged', pg_temp.job(a, pe, 'fail') is not null);
  r := billing.account_state(a, pe + interval '1 hour');
  perform pg_temp.eq('P5 failed try: past_due', r->>'state', 'past_due');
  perform pg_temp.eqt('P5 past_due since the first try', r->>'past_due_since', pe);
  perform pg_temp.eqt('P5 next retry day 3', r->>'next_retry_at', pe + interval '3 days');
  perform pg_temp.eq('P5 amount due shown', r->>'amount_due_minor', '4900');
  perform pg_temp.eq('P5 reading goes on', pg_temp.pp(a, pe + interval '1 hour', 990010501, 'read_now'), 'true');
  perform pg_temp.eq('P5 day 1: no try', pg_temp.job(a, pe + interval '1 day', 'fail'), null);
  perform pg_temp.ok('P5 day 3: retry', pg_temp.job(a, pe + interval '3 days', 'fail') is not null);
  perform pg_temp.eq('P5 day 3 again: no second try', pg_temp.job(a, pe + interval '3 days 2 hours', 'fail'), null);
  perform pg_temp.ok('P5 day 7: retry', pg_temp.job(a, pe + interval '7 days', 'fail') is not null);
  ref := pg_temp.job(a, pe + interval '14 days');
  perform pg_temp.ok('P5 day 14: retry', ref is not null);
  perform pg_temp.eq('P5 day-14 try paid on day 15, job not run yet: refunded',
    billing.apply_payment(ref, pg_temp.tx_ok(ref), pe + interval '15 days 1 hour')->>'reason', 'stale');
  perform pg_temp.eq('P5 four tries', (select count(*) from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
    where i.account = a and i.kind = 'renewal')::text, '4');
  perform pg_temp.job(a, pe + interval '15 days');
  r := billing.account_state(a, pe + interval '15 days');
  perform pg_temp.eq('P5 day 15: ended', r->>'state', 'ended');
  perform pg_temp.ok('P5 the job ended it on day 15', (select status = 'ended' and ended_at = pe + interval '15 days' from billing.subscriptions where account = a));
  perform pg_temp.ok('P5 open bill voided', not exists (select 1 from billing.invoices where account = a and status = 'open'));
  perform pg_temp.eq('P5 not read', pg_temp.pp(a, pe + interval '15 days', 990010501, 'read_now'), 'false');
  ref := (select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
           where i.account = a and i.kind = 'renewal' and pa.status = 'failed' order by pa.created_at desc limit 1);
  perform pg_temp.eq('P5 a late success on the void bill: refunded', billing.apply_payment(ref, pg_temp.tx_ok(ref), pe + interval '16 days')->>'reason', 'stale');
  perform pg_temp.fails('P5 restart: launch price refused (database)',
    format('insert into billing.subscriptions (account, plan, currency, interval, amount_minor, offer, status, started_at, billing_day, period_start, period_end) values (%L, ''home'', ''ZAR'', ''month'', 4900, ''launch'', ''active'', %L, 1, %L, %L)',
           a, pe + interval '20 days', pe + interval '20 days', pe + interval '50 days'), 'first-time');
  perform pg_temp.eq('P5 restart pays list price', billing.start_checkout(a, 'home', 'month', 0, '{990010501}', pe + interval '20 days')->>'amount_minor', '9900');
end $$;

do $$
declare a uuid := pg_temp.acct('p5b'); pe timestamptz;
begin
  update billing.markets set retry_days = '{0,2,5}' where code = 'ZA';
  perform pg_temp.link(a, 'p5b', '{990010551}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990010551}', pg_temp.t(0));
  pe := (pg_temp.sub(a)).period_end;
  perform pg_temp.job(a, pe, 'fail');
  perform pg_temp.eqt('P5 retry days come from the market row', pg_temp.st(a, pe + interval '1 hour', 'next_retry_at'), pe + interval '2 days');
  perform pg_temp.ok('P5 market day 2: retry', pg_temp.job(a, pe + interval '2 days', 'fail') is not null);
  perform pg_temp.eqt('P5 market: ends day 6', pg_temp.st(a, pe + interval '3 days', 'plan_ends_at'), pe + interval '6 days');
  update billing.markets set retry_days = '{0,3,7,14}' where code = 'ZA';
end $$;

-- ---------------------------------------------------------------------------
-- P6 paying inside the window keeps price and billing date; hard decline
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p6'); b uuid := pg_temp.acct('p6b'); pe timestamptz; inv uuid; ref text; r jsonb;
begin
  perform pg_temp.link(a, 'p6', '{990010601}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990010601}', pg_temp.t(0));
  pe := (pg_temp.sub(a)).period_end;
  perform pg_temp.job(a, pe, 'fail');
  perform pg_temp.fails('P6 no switching while past_due',
    format('select billing.set_chosen_plants(%L, ''{990010601}'', %L)', a, pe + interval '1 day'), 'past_due');
  perform pg_temp.fails('P6 no upgrade while past_due',
    format('select billing.upgrade(%L, ''family'', 0, ''{990010601}'', %L)', a, pe + interval '1 day'), 'failed payment first');
  inv := (billing.pay_now(a, pe + interval '5 days')->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'saved_card', pe + interval '5 days')->>'reference';
  r := pg_temp.answer(ref, 'ok', pe + interval '5 days');
  perform pg_temp.eq('P6 paid on day 5', r->>'action', 'applied');
  r := billing.account_state(a, pe + interval '5 days');
  perform pg_temp.eq('P6 active again', r->>'state', 'active');
  perform pg_temp.eqt('P6 billing date kept', r->>'next_charge_at', pe + interval '1 month');
  perform pg_temp.eq('P6 price kept', r->>'next_amount_minor', '4900');
  perform pg_temp.eq('P6 past_due_since cleared', r->>'past_due_since', null);
  perform pg_temp.eq('P6 next renewal day 3 does not retry the paid bill', pg_temp.job(a, pe + interval '6 days', 'fail'), null);

  perform pg_temp.link(b, 'p6b', '{990010602}', pg_temp.t(0));
  perform pg_temp.buy(b, 'home', 'month', '{990010602}', pg_temp.t(0), 'AUTH_b111');
  pe := (pg_temp.sub(b)).period_end;
  perform pg_temp.job(b, pe, 'hard');
  r := billing.account_state(b, pe + interval '1 hour');
  perform pg_temp.eq('P6 hard decline: past_due', r->>'state', 'past_due');
  perform pg_temp.eq('P6 hard decline: card switched off', r->>'card', null);
  perform pg_temp.ok('P6 hard decline recorded', exists (select 1 from billing.payment_methods where auth_ref = 'AUTH_b111' and disabled_reason = 'hard_decline'));
  perform pg_temp.eq('P6 hard decline: no retry on day 3', pg_temp.job(b, pe + interval '3 days', 'fail'), null);
  inv := (billing.pay_now(b, pe + interval '4 days')->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pe + interval '4 days')->>'reference';
  r := pg_temp.answer(ref, 'ok', pe + interval '4 days', 'AUTH_b222');
  perform pg_temp.eq('P6 new card pays: active', pg_temp.st(b, pe + interval '4 days', 'state'), 'active');
  perform pg_temp.eq('P6 new card saved', pg_temp.st(b, pe + interval '4 days', 'card')::jsonb->>'last4', 'b222');
end $$;

-- ---------------------------------------------------------------------------
-- P7 a late job catches up one step at a time; unknown results verified first;
--    a bank challenge
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p7'); b uuid := pg_temp.acct('p7b'); c uuid := pg_temp.acct('p7c'); pe timestamptz; ref text; r jsonb; inv uuid;
begin
  perform pg_temp.link(a, 'p7', '{990010701}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990010701}', pg_temp.t(0));
  pe := (pg_temp.sub(a)).period_end;
  perform pg_temp.eq('P7 job down: still active on day 8', pg_temp.st(a, pe + interval '8 days', 'state'), 'active');
  perform pg_temp.ok('P7 first run on day 8: one try', pg_temp.job(a, pe + interval '8 days', 'fail') is not null);
  perform pg_temp.eqt('P7 window starts at the first try', pg_temp.st(a, pe + interval '8 days', 'past_due_since'), pe + interval '8 days');
  perform pg_temp.eq('P7 same run time: no second try', pg_temp.job(a, pe + interval '8 days 1 minute', 'fail'), null);
  perform pg_temp.ok('P7 down again until day 8+12: one try only', pg_temp.job(a, pe + interval '20 days', 'fail') is not null);
  perform pg_temp.eq('P7 days 3 and 7 never fire together', pg_temp.job(a, pe + interval '20 days 1 minute', 'fail'), null);
  perform pg_temp.eq('P7 three tries in all', pg_temp.tries(a)::text, '3');

  -- unknown result: verify before any new try
  perform pg_temp.link(b, 'p7b', '{990010702}', pg_temp.t(0));
  perform pg_temp.buy(b, 'home', 'month', '{990010702}', pg_temp.t(0), 'AUTH_p7b');
  pe := (pg_temp.sub(b)).period_end;
  ref := pg_temp.job(b, pe, 'unknown');
  perform pg_temp.ok('P7 no answer: unknown', (select status = 'unknown' from billing.payment_attempts where reference = ref));
  perform pg_temp.eq('P7 unknown: still active (no failed try)', pg_temp.st(b, pe + interval '5 minutes', 'state'), 'active');
  perform pg_temp.eq('P7 lease held: no new try', pg_temp.job(b, pe + interval '5 minutes'), null);
  r := billing.run(pe + interval '15 minutes');
  perform pg_temp.ok('P7 lease over: listed to verify', r->'verify' ? ref);
  perform pg_temp.ok('P7 lease over: still no new try', not exists (select 1 from jsonb_array_elements(r->'charges') x where x->>'reference' <> ref
    and (select account from billing.invoices where id = (x->>'invoice')::uuid) = b));
  inv := (select invoice from billing.payment_attempts where reference = ref);
  perform pg_temp.ok('P7 Pay asks to verify first', billing.begin_attempt(inv, 'saved_card', pe + interval '20 minutes')->'verify' ? ref);
  r := pg_temp.answer(ref, 'ok', pe + interval '20 minutes');
  perform pg_temp.eq('P7 verify finds it paid: applied once', r->>'action', 'applied');
  perform pg_temp.eq('P7 paid: active', pg_temp.st(b, pe + interval '20 minutes', 'state'), 'active');

  -- a charge that never reached Paystack is void and does not count as a try
  pe := (pg_temp.sub(b)).period_end;
  ref := pg_temp.job(b, pe, 'not_found');
  perform pg_temp.ok('P7 never reached Paystack: void', (select status = 'void' from billing.payment_attempts where reference = ref));
  perform pg_temp.ok('P7 next run charges again', pg_temp.job(b, pe + interval '1 minute', 'ok') is not null);

  -- bank challenge: pending plus a pay link
  perform pg_temp.link(c, 'p7c', '{990010703}', pg_temp.t(0));
  perform pg_temp.buy(c, 'home', 'month', '{990010703}', pg_temp.t(0), 'AUTH_p7c');
  pe := (pg_temp.sub(c)).period_end;
  ref := pg_temp.job(c, pe, 'pending');
  r := billing.account_state(c, pe + interval '1 minute');
  perform pg_temp.eq('P7 bank challenge: past_due', r->>'state', 'past_due');
  perform pg_temp.eq('P7 bank challenge: pay link', r->>'pay_url', 'https://checkout.test/' || ref);
  perform pg_temp.eq('P7 challenge open: no retry inside the lease', pg_temp.job(c, pe + interval '30 minutes'), null);
  r := pg_temp.answer(ref, 'ok', pe + interval '40 minutes');
  perform pg_temp.eq('P7 challenge finished: applied', r->>'action', 'applied');
  perform pg_temp.eq('P7 challenge finished: active', pg_temp.st(c, pe + interval '40 minutes', 'state'), 'active');
end $$;

-- ---------------------------------------------------------------------------
-- P8 month ends: billing_day clamped each month, in the market's time zone
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p8'); s billing.subscriptions;
begin
  perform pg_temp.eqt('P8 31 Jan -> 28 Feb', billing.add_period('2027-01-31 10:00+02', 'month', 31, 'Africa/Johannesburg')::text, '2027-02-28 10:00+02');
  perform pg_temp.eqt('P8 28 Feb (day 31) -> 31 Mar', billing.add_period('2027-02-28 10:00+02', 'month', 31, 'Africa/Johannesburg')::text, '2027-03-31 10:00+02');
  perform pg_temp.eqt('P8 leap year: 31 Jan -> 29 Feb', billing.add_period('2028-01-31 10:00+02', 'month', 31, 'Africa/Johannesburg')::text, '2028-02-29 10:00+02');
  perform pg_temp.eqt('P8 yearly 29 Feb -> 28 Feb', billing.add_period('2028-02-29 10:00+02', 'year', 29, 'Africa/Johannesburg')::text, '2029-02-28 10:00+02');
  perform pg_temp.eqt('P8 local day, not UTC: 1 Mar 00:30 local', billing.add_period('2027-03-01 00:30+02', 'month', 1, 'Africa/Johannesburg')::text, '2027-04-01 00:30+02');
  perform pg_temp.link(a, 'p8', '{990010801}', '2027-01-31 10:00+02');
  perform pg_temp.buy(a, 'home', 'month', '{990010801}', '2027-01-31 10:00+02', 'AUTH_p8');
  s := pg_temp.sub(a);
  perform pg_temp.ok('P8 bought 31 Jan: billing day 31, due 28 Feb', s.billing_day = 31 and s.period_end = '2027-02-28 10:00+02');
  perform pg_temp.job(a, '2027-02-28 10:05+02', 'ok');
  perform pg_temp.ok('P8 renewed: due 31 Mar', (pg_temp.sub(a)).period_end = '2027-03-31 10:00+02');
  perform pg_temp.job(a, '2027-03-31 10:05+02', 'ok');
  perform pg_temp.ok('P8 renewed: due 30 Apr', (pg_temp.sub(a)).period_end = '2027-04-30 10:00+02');
end $$;

-- ---------------------------------------------------------------------------
-- P9 upgrade: prorated in the market's days, offer kept, billing day kept, waived
--    below the minimum, clears a booked downgrade; stale upgrade refunded
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p9'); r jsonb; inv uuid; ref text; s billing.subscriptions; pe timestamptz;
begin
  perform pg_temp.link(a, 'p9', '{990010901,990010902,990010903,990010904}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990010901,990010902}', pg_temp.t(0), 'AUTH_p9');
  pe := (pg_temp.sub(a)).period_end;
  perform pg_temp.fails('P9 upgrade to the same places refused',
    format('select billing.upgrade(%L, ''home'', 0, ''{990010901}'', %L)', a, pg_temp.t(10)), 'not more places');
  r := billing.upgrade(a, 'family', 0, '{990010901,990010902,990010903,990010904}', pg_temp.t(10));
  perform pg_temp.eq('P9 21 of 31 days of (9900 - 4900), rounded', r->>'amount_minor', '3387');
  perform pg_temp.eq('P9 not applied before paying', r->>'applied', 'false');
  perform pg_temp.eq('P9 still Home until paid', pg_temp.st(a, pg_temp.t(10), 'plan'), 'home');
  ref := billing.begin_attempt((r->>'invoice')::uuid, 'saved_card', pg_temp.t(10))->>'reference';
  perform pg_temp.ok('P9 saved card used', (select auth_ref = 'AUTH_p9' from billing.payment_methods where id =
    (select payment_method from billing.payment_attempts where reference = ref)));
  perform pg_temp.eq('P9 upgrade paid', pg_temp.answer(ref, 'ok', pg_temp.t(10), 'AUTH_p9')->>'action', 'applied');
  s := pg_temp.sub(a);
  perform pg_temp.ok('P9 Family at the launch price', s.plan = 'family' and s.amount_minor = 9900);
  perform pg_temp.eq('S9 offer kept on upgrade (real command)', s.offer, 'launch');
  perform pg_temp.ok('P9 billing day and date kept', s.billing_day = 1 and s.period_end = pe);
  perform pg_temp.eq('P9 the bound choice applied', pg_temp.st(a, pg_temp.t(10), 'chosen'), '4');
  -- stale: the account changes between the upgrade and the payment
  r := billing.upgrade(a, 'family', 1, '{990010901,990010902,990010903,990010904}', pg_temp.t(20));
  perform pg_temp.eq('P9 11 days of an extra place', r->>'amount_minor', '1029');
  ref := billing.begin_attempt((r->>'invoice')::uuid, 'card_page', pg_temp.t(20))->>'reference';
  perform billing.set_chosen_plants(a, '{990010901,990010902,990010903}', pg_temp.t(20));
  perform pg_temp.eq('P9 stale upgrade refunded', pg_temp.answer(ref, 'ok', pg_temp.t(20))->>'reason', 'stale');
  perform pg_temp.eq('P9 stale upgrade: places unchanged', pg_temp.st(a, pg_temp.t(20), 'places'), '5');
  -- below Paystack's minimum: waived, applied at once
  r := billing.upgrade(a, 'family', 1, '{990010901,990010902,990010903,990010904}', pg_temp.t(30));
  perform pg_temp.eq('P9 one day of an extra place (94 c): waived', r->>'status', 'waived');
  perform pg_temp.eq('P9 waived: applied', r->>'applied', 'true');
  perform pg_temp.eq('P9 waived: 6 places', pg_temp.st(a, pg_temp.t(30), 'places'), '6');
  -- a booked "fewer extra places", then an upgrade clears it
  perform billing.downgrade(a, 'family', 0, '{}', pg_temp.t(30));
  perform pg_temp.ok('P9 fewer places booked', (pg_temp.sub(a)).next_extra_places = 0);
  r := billing.upgrade(a, 'family', 2, '{990010901,990010902,990010903,990010904}', pg_temp.t(30));
  perform pg_temp.ok('P9 upgrade clears the booked downgrade', (pg_temp.sub(a)).next_extra_places is null and (pg_temp.sub(a)).next_price is null);
end $$;

-- ---------------------------------------------------------------------------
-- P10 downgrade needs the plants to drop; interval switch at the next billing date;
--     the offer stays on both
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p10'); r jsonb; s billing.subscriptions; pe timestamptz;
begin
  perform pg_temp.link(a, 'p10', '{990011001,990011002,990011003,990011004,990011005}', pg_temp.t(0));
  perform pg_temp.buy(a, 'family', 'month', '{990011001,990011002,990011003,990011004}', pg_temp.t(0), 'AUTH_p10');
  pe := (pg_temp.sub(a)).period_end;
  perform pg_temp.fails('P10 downgrade without enough plants to drop',
    format('select billing.downgrade(%L, ''home'', 0, ''{990011004}'', %L)', a, pg_temp.t(5)), 'pick 1 more');
  perform pg_temp.fails('P10 drop list must be chosen plants',
    format('select billing.downgrade(%L, ''home'', 0, ''{990011005,990011004}'', %L)', a, pg_temp.t(5)), 'not chosen');
  r := billing.downgrade(a, 'home', 0, '{990011003,990011004}', pg_temp.t(5));
  perform pg_temp.eq('P10 downgrade booked: next plan', r->>'next_plan', 'home');
  perform pg_temp.eq('P10 next amount: Home launch', r->>'next_amount_minor', '4900');
  perform pg_temp.eq('P10 still Family now', r->>'plan', 'family');
  perform pg_temp.fails('P10 a switch must still fit the next plan',
    format('select billing.set_chosen_plants(%L, ''{990011001,990011002,990011003,990011005}'', %L)', a, pg_temp.t(6)), 'drop first');
  r := pg_temp.choose(a, '{990011001,990011002,990011003}', pg_temp.t(6));
  perform pg_temp.eq('P10 switching out a dropped plant is fine', r->>'chosen', '3');
  r := billing.switch_interval(a, 'year', pg_temp.t(7));
  perform pg_temp.eq('P10 yearly booked', r->>'next_interval', 'year');
  perform pg_temp.eq('P10 downgrade kept', r->>'next_plan', 'home');
  perform pg_temp.eq('P10 Home launch yearly', r->>'next_amount_minor', '49000');
  perform pg_temp.ok('P10 renewal charged', pg_temp.job(a, pe, null) is not null);
  perform pg_temp.ok('P10 renewal bill at the booked amount',
    (select amount_minor = 49000 and interval = 'year' and plan = 'home' from billing.invoices where account = a and kind = 'renewal' and status = 'open'));
  perform pg_temp.answer((select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
                           where i.account = a and i.kind = 'renewal'), 'ok', pe);
  s := pg_temp.sub(a);
  perform pg_temp.ok('P10 renewed as Home yearly with the offer', s.plan = 'home' and s.interval = 'year'
    and s.amount_minor = 49000 and s.offer = 'launch' and s.next_price is null and s.period_end = pe + interval '1 year');
  r := billing.account_state(a, pe);
  perform pg_temp.eq('P10 dropped plants gone', r->>'chosen', '2');
  perform pg_temp.eq('P10 kept plant read', pg_temp.pp(a, pe, 990011001, 'read_now'), 'true');
  perform pg_temp.eq('P10 dropped plant locked', pg_temp.pp(a, pe, 990011003, 'locked'), 'true');
  -- undo a booking: back to the current plan
  perform billing.switch_interval(a, 'month', pe + interval '1 day');
  r := billing.switch_interval(a, 'year', pe + interval '1 day');
  perform pg_temp.ok('P10 switching back clears the booking', (pg_temp.sub(a)).next_price is null);
end $$;

-- ---------------------------------------------------------------------------
-- P11 cancel and undo; a late job ends it on the cancel date; restart pays list
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p11'); r jsonb; pe timestamptz;
begin
  perform pg_temp.link(a, 'p11', '{990011101}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990011101}', pg_temp.t(0), 'AUTH_p11');
  pe := (pg_temp.sub(a)).period_end;
  r := billing.cancel(a, pg_temp.t(3));
  perform pg_temp.eqt('P11 cancel booked', r->>'cancel_at', pe);
  perform pg_temp.eq('P11 cancel: no next charge', r->>'next_charge_at', null);
  r := billing.undo_cancel(a, pg_temp.t(4));
  perform pg_temp.eqt('P11 undo: next charge back', r->>'next_charge_at', pe);
  perform billing.cancel(a, pg_temp.t(5));
  perform pg_temp.fails('P11 nothing to delete while it runs',
    format('select billing.delete_account(%L, %L)', a, pg_temp.t(6)), 'cancel it and let it run out');
  perform pg_temp.eq('P11 cancelled: no charge on the date', pg_temp.job(a, pe + interval '3 days'), null);
  perform pg_temp.ok('P11 late job ends it on the cancel date', (select status = 'ended' and ended_at = pe from billing.subscriptions where account = a));
  perform pg_temp.fails('P11 undo after the end refused',
    format('select billing.undo_cancel(%L, %L)', a, pe + interval '4 days'), 'no cancel to undo');
  r := billing.start_checkout(a, 'home', 'month', 0, '{990011101}', pe + interval '5 days');
  perform pg_temp.eq('P11 restart pays list price', r->>'amount_minor', '9900');
  perform pg_temp.eq('P11 saved card offered', r->>'saved_card', 'true');
  perform pg_temp.eq('P11 restart on the saved card', pg_temp.answer(billing.begin_attempt((r->>'invoice')::uuid, 'saved_card', pe + interval '5 days')->>'reference',
    'ok', pe + interval '5 days', 'AUTH_p11')->>'action', 'applied');
  perform pg_temp.ok('P11 new billing day', (pg_temp.sub(a)).billing_day = extract(day from (pe + interval '5 days') at time zone 'Africa/Johannesburg'));
end $$;

-- ---------------------------------------------------------------------------
-- P12 disputes; card check; refunds retried
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p12'); b uuid := pg_temp.acct('p12b'); pe timestamptz; buy_ref text; ren_ref text; r jsonb; rf uuid; inv uuid; ref text;
begin
  perform pg_temp.link(a, 'p12', '{990011201}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990011201}', pg_temp.t(0), 'AUTH_p12');
  buy_ref := (select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice where i.account = a and i.kind = 'purchase');
  pe := (pg_temp.sub(a)).period_end;
  ren_ref := pg_temp.job(a, pe, 'ok');
  r := billing.record_dispute(buy_ref, 'charge.dispute.create', 'awaiting-merchant-feedback', false, null, pe + interval '2 days');
  perform pg_temp.eq('P12 dispute open: may not delete', pg_temp.st(a, pe + interval '2 days', 'may_delete'), 'false');
  r := billing.record_dispute(buy_ref, 'charge.dispute.resolve', 'lost', true, 4900, pe + interval '3 days');
  perform pg_temp.eq('P12 lost on an old period: owed', r->>'action', 'owed');
  r := billing.account_state(a, pe + interval '3 days');
  perform pg_temp.eq('P12 owed shown', r->>'owed_minor', '4900');
  perform pg_temp.eq('P12 old-period loss: plan runs on', r->>'state', 'active');
  r := billing.record_dispute(ren_ref, 'charge.dispute.resolve', 'lost', true, 4900, pe + interval '4 days');
  perform pg_temp.eq('P12 lost on the current period: plan ends at once', r->>'action', 'plan_ended');
  r := billing.account_state(a, pe + interval '4 days');
  perform pg_temp.eq('P12 ended', r->>'state', 'ended');
  perform pg_temp.eq('P12 card switched off', r->>'card', null);
  perform pg_temp.eq('P12 reading stops', pg_temp.pp(a, pe + interval '4 days', 990011201, 'read_now'), 'false');
  perform pg_temp.ok('P12 no retries after a lost dispute', pg_temp.job(a, pe + interval '7 days') is null);
  perform pg_temp.fails('P12 owed blocks delete', format('select billing.delete_account(%L, %L)', a, pe + interval '5 days'), 'money is owed');

  -- card check: the minimum on a new card, refunded
  perform pg_temp.link(b, 'p12b', '{990011202}', pg_temp.t(0));
  inv := (billing.start_card_check(b, pg_temp.t(0))->>'invoice')::uuid;
  perform pg_temp.ok('P12 card check is the market minimum', (select amount_minor = 100 from billing.invoices where id = inv));
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(0))->>'reference';
  r := pg_temp.answer(ref, 'ok', pg_temp.t(0), 'AUTH_chk1');
  perform pg_temp.ok('P12 card check: card saved, refund owed', (r->>'refund') is not null
    and pg_temp.st(b, pg_temp.t(0), 'card')::jsonb->>'last4' = 'chk1');
  rf := (r->>'refund')::uuid;
  r := billing.run(pg_temp.t(0));
  perform pg_temp.ok('P12 refund handed to the job', exists (select 1 from jsonb_array_elements(r->'refunds') x where (x->>'refund')::uuid = rf));
  perform billing.record_refund(rf, 'paystack 500: down', null, pg_temp.t(0));
  perform pg_temp.ok('P12 refund failed: not handed out again at once',
    not exists (select 1 from jsonb_array_elements(billing.run(pg_temp.t(0) + interval '30 minutes')->'refunds') x where (x->>'refund')::uuid = rf));
  perform pg_temp.ok('P12 failed refund retried', exists (select 1 from jsonb_array_elements(billing.run(pg_temp.t(0) + interval '61 minutes')->'refunds') x where (x->>'refund')::uuid = rf));
  perform billing.record_refund(rf, null, 'RF_1', pg_temp.t(0) + interval '62 minutes');
  perform billing.record_refund_event(ref, 'processed', 'RF_1', 100, null, pg_temp.t(1));
  perform pg_temp.ok('P12 refund processed', (select status = 'processed' and tries = 2 from billing.refunds where id = rf));
  perform billing.record_refund_event(buy_ref, 'processed', 'RF_hand', 2000, 'by hand', pg_temp.t(1));
  perform pg_temp.ok('P12 dashboard refund recorded against the try', exists (select 1 from billing.refunds r join billing.payment_attempts pa on pa.id = r.attempt
    where pa.reference = buy_ref and r.reason = 'manual' and r.amount_minor = 2000));
end $$;

-- ---------------------------------------------------------------------------
-- P13 delete_account
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p13'); b uuid := pg_temp.acct('p13b'); c uuid := pg_temp.acct('p13c'); pe timestamptz; ref text; r jsonb; inv uuid;
begin
  perform pg_temp.link(a, 'p13', '{990011301}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990011301}', pg_temp.t(0), 'AUTH_p13');
  ref := (select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice where i.account = a);
  pe := (pg_temp.sub(a)).period_end;
  perform pg_temp.fails('P13 active: refused', format('select billing.delete_account(%L, %L)', a, pg_temp.t(1)), 'cancel it');
  perform billing.cancel(a, pg_temp.t(1));
  perform pg_temp.fails('P13 cancel booked, plan still running: refused', format('select billing.delete_account(%L, %L)', a, pg_temp.t(2)), 'cancel it');
  perform billing.record_dispute(ref, 'charge.dispute.create', 'pending', false, null, pe + interval '1 day');
  perform pg_temp.fails('P13 ended, dispute open: refused', format('select billing.delete_account(%L, %L)', a, pe + interval '2 days'), 'dispute is open');
  perform billing.record_dispute(ref, 'charge.dispute.resolve', 'won', false, null, pe + interval '3 days');
  inv := (select invoice from billing.payment_attempts where reference = ref);
  r := billing.delete_account(a, pe + interval '4 days');
  perform pg_temp.eq('P13 ended, nothing owed: deleted', r->>'deleted', 'true');
  perform pg_temp.eq('P13 its plant loses protection', r->>'unprotected', '[990011301]');
  perform pg_temp.ok('P13 account gone', not exists (select 1 from billing.accounts where id = a));
  perform pg_temp.ok('P13 bill and try kept, account cleared', exists (select 1 from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id
    where i.id = inv and i.account is null and i.amount_minor = 4900 and pa.reference = ref));
  perform pg_temp.ok('P13 card kept, account cleared', exists (select 1 from billing.payment_methods where auth_ref = 'AUTH_p13' and account is null));
  perform pg_temp.ok('P13 plant keeps its used week', (select trial_used_at is not null and trial_used_by is null from billing.plants where id = 990011301));
  -- a payment for a deleted account refunds itself
  perform pg_temp.link(b, 'p13b', '{990011302}', pg_temp.t(0));
  inv := (billing.start_checkout(b, 'home', 'month', 0, '{990011302}', pg_temp.t(0))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(0))->>'reference';
  perform pg_temp.eq('P13 none: may delete', pg_temp.st(b, pg_temp.t(0), 'may_delete'), 'true');
  perform billing.delete_account(b, pg_temp.t(0) + interval '1 minute');
  r := pg_temp.answer(ref, 'ok', pg_temp.t(0) + interval '2 minutes');
  perform pg_temp.eq('P13 paid after the delete: refunded', r->>'reason', 'unknown_account');
  perform pg_temp.ok('P13 open bill voided on delete', (select status = 'void' from billing.invoices where id = inv));
  -- trialing may delete
  perform pg_temp.link(c, 'p13c', '{990011303}', pg_temp.t(0));
  perform pg_temp.choose(c, '{990011303}', pg_temp.t(0));
  perform pg_temp.eq('P13 trialing: deleted', billing.delete_account(c, pg_temp.t(1))->>'deleted', 'true');
end $$;

-- ---------------------------------------------------------------------------
-- P14 paying in the free week ends the week; copy refuses once payments exist
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p14'); r jsonb;
begin
  perform pg_temp.link(a, 'p14', '{990011401,990011402}', pg_temp.t(0));
  perform pg_temp.choose(a, '{990011401}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990011401,990011402}', pg_temp.t(2), 'AUTH_p14');
  r := billing.account_state(a, pg_temp.t(2));
  perform pg_temp.eq('P14 paid in the week: active', r->>'state', 'active');
  perform pg_temp.eqt('P14 week ends on payment', r->>'trial_ends_at', pg_temp.t(2));
  perform pg_temp.eq('P14 second plant seated with the payment', r->>'chosen', '2');
  perform pg_temp.fails('P14 copy refuses once payments exist', 'select billing.copy_from_old()', 'already hold payments');
end $$;


-- ---------------------------------------------------------------------------
-- P15 the billing function's door (public.billing_v2)
-- ---------------------------------------------------------------------------
do $$
declare u uuid := gen_random_uuid(); r jsonb; ref text;
begin
  insert into auth.users (id, email, created_at) values (u, 'door@state.test', now());
  r := public.billing_v2('account_state', jsonb_build_object('user', u));
  perform pg_temp.eq('P15 first call makes the account', r->>'state', 'none');
  perform billing.link_login((select id from billing.accounts where user_id = u), 'sunsynk', 'door', null, '[{"id":990011501}]');
  r := public.billing_v2('start_checkout', jsonb_build_object('user', u, 'plan', 'home', 'interval', 'month', 'plants', '[990011501]'::jsonb));
  ref := public.billing_v2('begin_attempt', jsonb_build_object('invoice', r->>'invoice', 'channel', 'card_page'))->>'reference';
  perform pg_temp.eq('P15 owner of a try', public.billing_v2('attempt_user', jsonb_build_object('reference', ref))->>'user', u::text);
  r := public.billing_v2('apply_payment', jsonb_build_object('reference', ref, 'tx', pg_temp.tx_ok(ref, 'AUTH_door')));
  perform pg_temp.ok('P15 apply answers with the user and first-plan facts', r->>'action' = 'applied' and r->>'user' = u::text
    and r ? 'days_since_plan' and r->'days_since_plan' = 'null'::jsonb);
  perform pg_temp.ok('P15 not callable by signed-in users',
    not has_function_privilege('authenticated', 'public.billing_v2(text, jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.billing_v2(text, jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'billing.apply_payment(text, jsonb, timestamptz)', 'execute'));
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
