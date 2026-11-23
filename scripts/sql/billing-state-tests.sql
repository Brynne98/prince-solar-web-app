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
-- the account's latest plan row
create function pg_temp.sub(p_acc uuid) returns billing.subscriptions language sql as $$
  select * from billing.subscriptions where account = p_acc order by started_at desc limit 1
$$;
-- Stands in for the daily job (phase 2): records the first failed renewal try.
create function pg_temp.fail_renewal(p_sub uuid, p_at timestamptz) returns void language sql as $$
  update billing.subscriptions set status = 'past_due', past_due_since = p_at where id = p_sub
$$;

-- ---------------------------------------------------------------------------
-- L1 (final re-score, Sol) the link and claim writes and the account delete wait for a
--    billing run, which the copy holds exclusive, so none of them runs across the copy.
--    A share claim before the switch writes the old row and its billing claim in one
--    transaction, and reads the switch under that lock. First in the file, while this
--    transaction holds no billing-run lock yet: each call runs in a block that is rolled
--    back, which lets go of the locks it took.
-- ---------------------------------------------------------------------------
create function pg_temp.run_lock_held() returns text language sql as $$
  select string_agg(mode, ',' order by mode) from pg_locks where locktype = 'advisory'
     and classid = 3 and objid = 0 and objsubid = 2 and pid = pg_backend_pid() and granted
$$;
-- runs p_sql in a block that is rolled back: the billing-run lock it held ('none'), or its error
create function pg_temp.run_lock_of(p_sql text) returns text language plpgsql as $$
declare held text;
begin
  begin
    execute p_sql;
    held := coalesce(pg_temp.run_lock_held(), 'none');
    raise exception 'run_lock_of: undo';
  exception when others then
    if sqlerrm <> 'run_lock_of: undo' then held := 'error: ' || sqlerrm; end if;
  end;
  return held;
end $$;

do $$
declare a uuid := pg_temp.acct('l1'); u uuid; sh uuid; su uuid := gen_random_uuid(); r jsonb;
        pre text; pre_both boolean; pre_err text; live text; live_ok boolean; err text;
begin
  select user_id into u from billing.accounts where id = a;
  perform pg_temp.pay(a, 'home', 'month', now());
  perform pg_temp.ok('L1 starts with no billing-run lock held', pg_temp.run_lock_held() is null, pg_temp.run_lock_held());
  perform pg_temp.eq('L1 a link or claim write waits for a billing run',
    pg_temp.run_lock_of(format('select public.billing_links(%L, %L)', 'claim_plant',
                               jsonb_build_object('user', u, 'plant', 990150001, 'name', 'L1'))), 'ShareLock');
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('L1 the account delete (old or new) waits for a billing run',
    pg_temp.run_lock_of('select public.api_account_delete()'), 'ShareLock');
  perform set_config('request.jwt.claims', '', true);

  begin
    -- the one share login, made here when there is none (pg_temp.share_login comes later in the file)
    select id into sh from private.sunsynk_accounts where kind = 'share';
    if sh is null then
      insert into auth.users (id, email, created_at) values (su, 'l1share@state.test', now());
      insert into private.sunsynk_accounts (user_id, sunsynk_username, status, kind) values (su, 'l1share', 'active', 'share')
      returning id into sh;
    end if;
    update private.sunsynk_accounts set status = 'active' where id = sh;
    r := public.share_claim_any(u, sh, 990150002, 'L1 shared');
    pre := r->>'result'; pre_err := r->>'copy_error';
    pre_both := exists (select 1 from public.plant_users where plant_id = 990150002 and user_id = u and via_share)
            and exists (select 1 from billing.plant_claims where plant = 990150002 and account = a);
    -- switched: billing decides with the link row (share_claim_live), no old tick is written
    insert into billing.switch_over (switched_at) values (now());
    r := public.share_claim_any(u, sh, 990150003, 'L1 live');
    live := r->>'result';
    live_ok := exists (select 1 from billing.plant_claims where plant = 990150003 and account = a)
           and not exists (select 1 from private.plant_picks where user_id = u and plant_id = 990150003);
    raise exception 'L1: undo';
  exception when others then
    if sqlerrm <> 'L1: undo' then err := sqlerrm; end if;
  end;
  perform pg_temp.ok('L1 share claims run', err is null, err);
  perform pg_temp.ok('L1 before the switch: claimed', pre in ('claimed', 'claimed_paused'), pre);
  perform pg_temp.ok('L1 ... the old row and the billing claim in the same call', pre_both, pre_err);
  perform pg_temp.eq('L1 switched: claimed by the live rules', live, 'claimed');
  perform pg_temp.ok('L1 ... billing claim written, no old tick', live_ok);
exception when others then perform set_config('request.jwt.claims', '', true); perform pg_temp.ok('L1 runs', false, sqlerrm);
end $$;

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
  -- no card to charge: no retry date to promise (review fix 11)
  perform pg_temp.fail_renewal(s, p);
  perform pg_temp.eq('S7 past due, no card: no retry date', pg_temp.st(a, p + interval '1 day', 'next_retry_at'), null);
  perform pg_temp.eq('S7 past due, no card: no charge date', pg_temp.st(a, p + interval '1 day', 'next_charge_at'), null);
  insert into billing.payment_methods (account, provider, auth_ref, reusable, last4, exp_month, exp_year, active, created_at)
  values (a, 'paystack', 'AUTH_s7', true, '0007', 12, 2030, true, pg_temp.t(0));
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
  u3 uuid := gen_random_uuid(); lg3 uuid := gen_random_uuid();
  u4 uuid := gen_random_uuid(); lg4 uuid := gen_random_uuid(); u5 uuid := gen_random_uuid(); lg5 uuid := gen_random_uuid();
  u6 uuid := gen_random_uuid(); lg6 uuid := gen_random_uuid();
  a1 uuid; a2 uuid; a3 uuid; r jsonb;
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
          '{"authorization_code":"AUTH_copy1","last4":"4081","exp_month":"12","exp_year":"2030","reusable":true,"card_type":"visa "}', 'copy1@state.test');
  insert into public.plant_users (plant_id, user_id, plant_name, via_share) values (990001404, u2, 'Farm', true);
  insert into private.plant_picks (user_id, plant_id, held, picked_at) values (u2, 990001404, true, '2026-11-10 12:00+02');
  insert into private.billing (user_id, plan, comped, created_at) values (u2, 'family', true, '2026-11-10');
  -- review fix 14: a failed card mid-window, a downgrade booked with one plant to drop, a card saved with no email
  insert into auth.users (id, email, created_at) values (u3, 'copy3@state.test', '2026-10-01');
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values (lg3, u3, 'copy3', 'active', 'login');
  insert into public.plant_users (plant_id, user_id, account_id, plant_name, paused) values
    (990001411, u3, lg3, 'A', false), (990001412, u3, lg3, 'B', false), (990001413, u3, lg3, 'C', false);
  insert into private.plant_picks (user_id, plant_id, held, picked_at) values
    (u3, 990001411, true, '2026-10-01'), (u3, 990001412, true, '2026-10-01'), (u3, 990001413, true, '2026-10-01');
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, past_due_since, next_plan,
                               plants_to_remove, created_at, card)
  -- as the old billing writes it: billing_renew moved the date on to 20 Dec, then the 20 Nov charge failed
  values (u3, 'family', 'monthly', 20, '2026-12-20', 'past_due', '2026-11-20', 'home', '{990001413}', '2026-10-01',
          '{"authorization_code":"AUTH_copy3","last4":"0003","exp_month":"12","exp_year":"2030","reusable":true}');
  -- phase 3 fix 28: u4 an old removal list with nothing booked; u5 fewer extra places booked, too many plants
  insert into auth.users (id, email, created_at) values (u4, 'copy4@state.test', '2026-10-01'), (u5, 'copy5@state.test', '2026-10-01');
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values
    (lg4, u4, 'copy4', 'active', 'login'), (lg5, u5, 'copy5', 'active', 'login');
  insert into public.plant_users (plant_id, user_id, account_id, plant_name, paused) values
    (990001421, u4, lg4, 'A', false), (990001422, u4, lg4, 'B', false);
  insert into private.plant_picks (user_id, plant_id, held, picked_at) values
    (u4, 990001421, true, '2026-10-01'), (u4, 990001422, true, '2026-10-01');
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, plants_to_remove, created_at)
  values (u4, 'home', 'monthly', 20, '2026-12-20', 'active', '{990001422}', '2026-10-01');
  insert into public.plant_users (plant_id, user_id, account_id, plant_name, paused)
  select 990001430 + x, u5, lg5, 'P' || x, false from generate_series(1, 6) x;
  insert into private.plant_picks (user_id, plant_id, held, picked_at)
  select u5, 990001430 + x, true, '2026-10-01' from generate_series(1, 6) x;
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, extra_plants, next_extra_plants, created_at)
  values (u5, 'family', 'monthly', 20, '2026-12-20', 'active', 1, 0, '2026-10-01');
  -- final review (Neon): a downgrade booked on the old screens keeps its list of plants to
  -- keep (next_keep) and leaves plants_to_remove empty; the third plant is the one that stops
  insert into auth.users (id, email, created_at) values (u6, 'copy6b@state.test', '2026-10-01');
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values (lg6, u6, 'copy6b', 'active', 'login');
  insert into public.plant_users (plant_id, user_id, account_id, plant_name, paused, linked_at) values
    (990001441, u6, lg6, 'A', false, '2026-10-01'), (990001442, u6, lg6, 'B', false, '2026-10-01'), (990001443, u6, lg6, 'C', false, '2026-10-01');
  insert into private.plant_picks (user_id, plant_id, held, picked_at) values
    (u6, 990001441, true, '2026-10-01'), (u6, 990001442, true, '2026-10-01'), (u6, 990001443, true, '2026-10-01');
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, next_plan, next_keep, plants_to_remove, created_at)
  values (u6, 'family', 'monthly', 20, '2026-12-20', 'active', 'home', '{990001443,990001441}', '{}', '2026-10-01');
  set local session_replication_role = origin;

  insert into billing.refunds (reference, reason, status, created_at, updated_at) values ('S14-REF', 'manual', 'processed', now(), now());
  perform pg_temp.fails('S14 copy refused once a refund is recorded', 'select billing.copy_from_old()', 'already hold payments');
  delete from billing.refunds where reference = 'S14-REF';
  -- a rerun clears only what the copy wrote: the poller's and the commands' events stay
  perform billing.copy_from_old();
  -- the copy holds the billing-run lock the poller's share update and the link and claim writes
  -- wait on: a share removed while it copies cannot leave its claim behind (final review, Sol)
  perform pg_temp.ok('S14 the copy holds the billing-run lock', exists (select 1 from pg_locks where locktype = 'advisory'
    and classid = 3 and objid = 0 and objsubid = 2 and mode = 'ExclusiveLock' and pid = pg_backend_pid() and granted));
  insert into billing.account_events (account, at, actor, kind)
  select id, now(), 'copy', 'copy_needs_review' from billing.accounts where user_id = u1
  union all select id, now(), 'poller', 'login_seen' from billing.accounts where user_id = u1;
  a3 := (select id from billing.accounts where user_id = u1);
  perform billing.copy_from_old();
  perform pg_temp.ok('S14 rerun keeps the account id', a3 is not null and (select id from billing.accounts where user_id = u1) = a3);
  perform pg_temp.ok('S14 poller and command events kept', exists (select 1 from billing.account_events
    where account = a3 and actor = 'poller' and kind = 'login_seen'));
  perform pg_temp.ok('S14 the copy''s own events cleared', not exists (select 1 from billing.account_events
    where account = a3 and actor = 'copy'));
  a3 := (select id from billing.accounts where user_id = u3);
  perform pg_temp.ok('S14 past due copied with its failed day-0 try', exists (select 1 from billing.payment_attempts pa
    join billing.invoices i on i.id = pa.invoice where i.account = a3 and i.kind = 'renewal' and pa.channel = 'none'
     and pa.status = 'failed' and pa.created_at = '2026-11-20 00:00+02'));
  perform pg_temp.ok('S14 so day 0 is not charged again', not exists (select 1 from jsonb_array_elements(billing.run('2026-11-21 10:00+02')->'charges') x
    where (select account from billing.invoices where id = (x->>'invoice')::uuid) = a3));
  perform pg_temp.ok('S14 card with no saved email takes the sign-in email', exists (select 1 from billing.payment_methods
    where account = a3 and auth_ref = 'AUTH_copy3' and auth_email = 'copy3@state.test'));
  perform pg_temp.ok('S14 the plant picked to go is marked to drop', (select array_agg(plant) = '{990001413}' from billing.seats
    where account = a3 and drop_at_period_end));
  perform pg_temp.ok('S14 kept plants fit Home: no review', not exists (select 1 from billing.account_events where account = a3));
  perform pg_temp.ok('S14 removal list with nothing booked: no plant marked to drop', not exists (select 1 from billing.seats se
    join billing.accounts a on a.id = se.account where a.user_id = u4 and se.drop_at_period_end));
  perform pg_temp.ok('S14 downgrade booked with a keep list: the plant not kept is marked to drop',
    (select array_agg(se.plant order by se.plant) = '{990001442}' from billing.seats se join billing.accounts a on a.id = se.account
      where a.user_id = u6 and se.drop_at_period_end));
  perform pg_temp.ok('S14 ... so it is not flagged for review', not exists (select 1 from billing.account_events e
    join billing.accounts a on a.id = e.account where a.user_id = u6 and e.kind = 'copy_needs_review'));
  -- the old run would drop the plant over the next places itself (private.billing_drops): marked to drop, no review
  perform pg_temp.ok('S14 fewer extra places booked, too many plants: the one over marked to drop', (select count(*) = 1
    from billing.seats se join billing.accounts a on a.id = se.account where a.user_id = u5 and se.drop_at_period_end)
    and not exists (select 1 from billing.account_events e join billing.accounts a on a.id = e.account
                     where a.user_id = u5 and e.kind = 'copy_needs_review'));
  perform pg_temp.ok('S14 past due: the unpaid period is 20 Oct to 20 Nov', (select period_start = '2026-10-20 00:00+02'
    and period_end = '2026-11-20 00:00+02' from billing.subscriptions where account = a3));
  -- this test's accounts only: a local database may hold other old billing rows, copied too
  delete from billing.payment_attempts where gateway_response is distinct from 'copied: past due at the switch-over'
     and invoice in (select i.id from billing.invoices i join billing.accounts a on a.id = i.account
                      where a.user_id in (u1, u2, u3, u4, u5));
  update private.billing set plants_to_remove = '{}' where user_id = u3;
  -- the old day-1 retry of the 20 Nov renewal, sent and not answered
  set local session_replication_role = replica;
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, claimed_at, tried_on)
  values ('psh_s14retry', u3, 'renewal', 'family', 'monthly', 199, 'pending', '2026-11-20', '2026-11-21', '2026-11-21 08:00+02',
          '2026-11-21 08:00+02', '2026-11-21');
  set local session_replication_role = origin;
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
  -- Paystack sends the brand with a space ("visa ", seen 2026-11-23): stored without it
  perform pg_temp.eq('S14 copied card brand trimmed', (select card_type from billing.payment_methods where account = a1 and auth_ref = 'AUTH_copy1'), 'visa');
  perform pg_temp.ok('S14 share claim copied', exists (select 1 from billing.plant_claims where plant = 990001404 and account = a2));
  perform pg_temp.eq('S14 comped: grant of 5', pg_temp.st(a2, '2026-11-22 12:00+02', 'places'), '5');
  perform pg_temp.eq('S14 shared plant read', pg_temp.pp(a2, '2026-11-22 12:00+02', 990001404, 'read_now'), 'true');
  r := billing.copy_from_old();
  perform pg_temp.eq('S14 rerun with the seed tries is allowed; plants over the next places marked, none left for review', r->>'needs_review', '0');
  perform pg_temp.ok('S14 the open old retry is a try on the 20 Nov renewal bill', exists (select 1 from billing.payment_attempts pa
    join billing.invoices i on i.id = pa.invoice join billing.subscriptions s on s.id = i.subscription
    where pa.reference = 'psh_s14retry' and pa.status = 'unknown' and i.kind = 'renewal' and i.period_start = '2026-11-20 00:00+02'
      and s.account = (select id from billing.accounts where user_id = u3)));
  perform pg_temp.ok('S14 second run copies fresh, no duplicates',
    (select count(*) = 1 from billing.seats s join billing.accounts a on a.id = s.account where a.user_id = u1)
    and (select count(*) = 1 from billing.subscriptions s join billing.accounts a on a.id = s.account where a.user_id = u1));
end $$;

-- ---------------------------------------------------------------------------
-- S15 old charges copied: a Paystack answer after the switch finds its reference.
-- Runs in a block that is rolled back, so phase 2 starts as S14 left it.
-- ---------------------------------------------------------------------------
do $$
declare
  u6 uuid := gen_random_uuid(); lg6 uuid := gen_random_uuid(); u7 uuid := gen_random_uuid(); lg7 uuid := gen_random_uuid();
  a6 uuid; a7 uuid; r jsonb; res jsonb := '[]'; x jsonb;
  d0 date := current_date - 2; nb date;
begin
  begin
    nb := public.billing_step(d0, 'monthly', extract(day from d0)::int, 1);
    set local session_replication_role = replica;
    insert into auth.users (id, email, created_at) values (u6, 'copy6@state.test', now() - interval '3 days'),
                                                          (u7, 'copy7@state.test', now() - interval '90 days');
    insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values
      (lg6, u6, 'copy6', 'active', 'login'), (lg7, u7, 'copy7', 'active', 'login');
    insert into public.plant_users (plant_id, user_id, account_id, plant_name, paused) values
      (990001501, u6, lg6, 'A', false), (990001511, u7, lg7, 'B', false);
    insert into private.plant_picks (user_id, plant_id, held, picked_at) values
      (u6, 990001501, true, now() - interval '3 days'), (u7, 990001511, true, now() - interval '90 days');
    insert into private.free_week_logins (sunsynk_username, user_id, started_at) values ('copy6', u6, now() - interval '3 days');
    -- u6: on the card page for Home when the old payments stopped
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, plants)
    values ('psh_s15start', u6, 'start', 'home', 'monthly', 99, 'pending', current_date, current_date, now() - interval '10 minutes', '{990001501}');
    -- u7: Home monthly; the old run moved the billing date on and the renewal charge is open;
    -- last month's renewal was paid
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, created_at, card)
    values (u7, 'home', 'monthly', extract(day from d0)::int, nb, 'active', now() - interval '90 days',
            '{"authorization_code":"AUTH_copy7","last4":"0007","exp_month":"12","exp_year":"2030","reusable":true}');
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at) values
      ('psh_s15renew', u7, 'renewal', 'home', 'monthly', 99, 'pending', d0, d0, now() - interval '1 hour', null),
      ('psh_s15paid', u7, 'renewal', 'home', 'monthly', 99, 'paid', public.billing_step(d0, 'monthly', extract(day from d0)::int, -1),
       d0 - 30, now() - interval '30 days', now() - interval '30 days');
    set local session_replication_role = origin;

    perform billing.copy_from_old();
    perform billing.copy_from_old();                     -- step 6 copies again: the old charges allow it
    insert into billing.switch_over (switched_at) values (now());
    a6 := (select id from billing.accounts where user_id = u6);
    a7 := (select id from billing.accounts where user_id = u7);

    r := billing.apply_payment('psh_s15start', jsonb_build_object('status', 'success', 'reference', 'psh_s15start',
           'amount', 9900, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now(),
           'authorization', jsonb_build_object('authorization_code', 'AUTH_copy6', 'reusable', true, 'last4', '0006',
                                               'exp_month', '12', 'exp_year', '2030', 'card_type', 'visa', 'signature', 'SIG_copy6'),
           'customer', jsonb_build_object('email', 'copy6@state.test', 'customer_code', 'CUS_copy6')), now());
    res := res || jsonb_build_object('l', 'S15 an old open start, paid after the switch: applied, not refunded',
                                     'p', r->>'action' = 'applied' and r->>'kind' = 'purchase', 'd', r::text);
    res := res || jsonb_build_object('l', 'S15 ... and the plan runs with its plant',
      'p', exists (select 1 from billing.subscriptions where account = a6 and plan = 'home' and status = 'active')
           and exists (select 1 from billing.seats where account = a6 and plant = 990001501 and closed_at is null));

    r := billing.apply_payment('psh_s15renew', jsonb_build_object('status', 'success', 'reference', 'psh_s15renew',
           'amount', 9900, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    res := res || jsonb_build_object('l', 'S15 an old open renewal, paid after the switch: applied to its own period',
      'p', r->>'action' = 'applied' and r->>'kind' = 'renewal'
           and exists (select 1 from billing.subscriptions where account = a7 and status = 'active'
                          and period_start = d0::timestamp at time zone 'Africa/Johannesburg'
                          and period_end = nb::timestamp at time zone 'Africa/Johannesburg'), 'd', r::text);

    r := billing.apply_payment('psh_s15paid', jsonb_build_object('status', 'success', 'reference', 'psh_s15paid',
           'amount', 9900, 'currency', 'ZAR', 'gateway_response', 'Approved'), now());
    res := res || jsonb_build_object('l', 'S15 an old paid charge answered again: nothing refunded', 'p', r->>'action' = 'again', 'd', r::text);
    res := res || jsonb_build_object('l', 'S15 no refund for any old reference',
      'p', not exists (select 1 from billing.refunds where reference like 'psh_s15%'));
    raise exception 's15 undo';
  exception when others then
    if sqlerrm <> 's15 undo' then res := res || jsonb_build_object('l', 'S15 runs', 'p', false, 'd', sqlerrm); end if;
  end;
  for x in select * from jsonb_array_elements(res) loop
    perform pg_temp.ok(x->>'l', (x->>'p')::boolean, x->>'d');
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- S16 copy: what the old billing really writes (verify fixes 5-11). Rolled back like S15.
--   u8  past due: the old run moved next_billing_date on, then the renewal failed; a settle
--       page is open for it (fix 7)
--   u9  billing day 31, next date 30 Apr: the period starts 31 Mar (fix 8)
--   u10 last renewal paid, then reversed after the switch: that period ends (fix 6)
--   u11 two open upgrades to Family adding plant C: one bill; seats A, B and C (fixes 9, 10)
--   u12 an open switch to yearly on Home; u13 an open upgrade Home monthly -> Family yearly (fix 11)
--   u14 an old refund owed, an open dispute, a lost dispute owed, a stuck card-check refund (fix 5)
-- ---------------------------------------------------------------------------
do $$
declare
  tz constant text := 'Africa/Johannesburg';
  u8 uuid := gen_random_uuid(); u9 uuid := gen_random_uuid(); u10 uuid := gen_random_uuid(); u11 uuid := gen_random_uuid();
  u12 uuid := gen_random_uuid(); u13 uuid := gen_random_uuid(); u14 uuid := gen_random_uuid();
  l11 uuid := gen_random_uuid();
  a uuid; s billing.subscriptions; bi billing.invoices; r jsonb; res jsonb := '[]'; x jsonb;
  d8 date := current_date - 3; nb10 date := current_date + 20; nb12 date := current_date + 10;
  old timestamptz := now() - interval '200 days';
begin
  begin
    set local session_replication_role = replica;
    insert into auth.users (id, email, created_at)
    select u, 'copy-s16-' || n || '@state.test', now() - interval '300 days'
      from unnest(array[u8, u9, u10, u11, u12, u13, u14]) with ordinality t (u, n);
    -- u8: renewal due d8 failed; billing_renew had moved the date a month on first
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, past_due_since, created_at, card)
    values (u8, 'home', 'monthly', extract(day from d8)::int, public.billing_step(d8, 'monthly', extract(day from d8)::int, 1),
            'past_due', d8, old, '{"authorization_code":"AUTH_s16u8","last4":"0008","exp_month":"12","exp_year":"2030","reusable":true}');
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, error, due_on, created_on, created_at, settled_at, tried_on) values
      ('psh_s16u8fail', u8, 'renewal', 'home', 'monthly', 99, 'failed', 'Insufficient Funds', d8, d8, now() - interval '3 days', now() - interval '3 days', d8),
      ('psh_s16u8settle', u8, 'settle', 'home', 'monthly', 99, 'pending', null, d8, current_date, now() - interval '5 minutes', null, null);
    -- u9: month end
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, created_at)
    values (u9, 'home', 'monthly', 31, '2027-04-30', 'active', old);
    -- u10: paid renewal for the current period
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, created_at)
    values (u10, 'home', 'monthly', extract(day from nb10)::int, nb10, 'active', old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at, tried_on)
    values ('psh_s16u10', u10, 'renewal', 'home', 'monthly', 99, 'paid',
            public.billing_step(nb10, 'monthly', extract(day from nb10)::int, -1), current_date - 10, now() - interval '10 days',
            now() - interval '10 days', current_date - 10);
    -- u11: Home with A and B read, C stopped; two card pages for Family adding C
    insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values (l11, u11, 's16u11', 'active', 'login');
    insert into public.plant_users (plant_id, user_id, account_id, plant_name, paused) values
      (990001611, u11, l11, 'A', false), (990001612, u11, l11, 'B', false), (990001613, u11, l11, 'C', true);
    insert into private.plant_picks (user_id, plant_id, held, picked_at) values
      (u11, 990001611, true, old), (u11, 990001612, true, old), (u11, 990001613, false, old);
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, created_at)
    values (u11, 'home', 'monthly', extract(day from nb12)::int, nb12, 'active', old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, added, extra_plants, plants, amount, status, due_on, created_on, created_at, billing_date) values
      ('psh_s16u11a', u11, 'upgrade', 'family', 'monthly', 0, 0, '{990001613}', 30, 'pending', current_date, current_date, now() - interval '20 minutes', nb12),
      ('psh_s16u11b', u11, 'upgrade', 'family', 'monthly', 0, 0, '{990001613}', 30, 'pending', current_date, current_date, now() - interval '10 minutes', nb12);
    -- u12: Home monthly, a year of Home bought from the billing date (0138's switch)
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, created_at)
    values (u12, 'home', 'monthly', extract(day from nb12)::int, nb12, 'active', old),
           (u13, 'home', 'monthly', extract(day from nb12)::int, nb12, 'active', old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, added, extra_plants, amount, status, due_on, created_on, created_at, billing_date) values
      ('psh_s16u12', u12, 'switch', 'home', 'yearly', 0, 0, 990, 'pending', current_date, current_date, now() - interval '10 minutes', nb12),
      -- u13: Family yearly from today, the unused month taken off (SOLAR-364)
      ('psh_s16u13', u13, 'upgrade', 'family', 'yearly', 0, 0, 1960, 'pending', current_date, current_date, now() - interval '10 minutes', nb12);
    -- u14: old charges, settled long ago, still open in some way
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, error, due_on, created_on, created_at, settled_at,
                                         refund_status, refund_tries, refund_alerted, refunded_cents, dispute, dispute_lost, dispute_owed) values
      ('psh_s16r1', u14, 'start', 'home', 'monthly', 99, 'paid', 'refund: paid after the account changed (stale; free, active)',
       old::date, old::date, old, old, 'failed', 2, false, null, null, false, false),
      ('psh_s16r2', u14, 'renewal', 'home', 'monthly', 99, 'paid', null, old::date, old::date, old, old,
       null, 0, false, null, 'awaiting-merchant-feedback', false, false),
      ('psh_s16r3', u14, 'renewal', 'home', 'monthly', 99, 'paid', null, old::date, old::date, old, old,
       'done', 0, false, 9900, 'lost', true, true),
      ('psh_s16r4', u14, 'card', 'home', 'monthly', 1, 'paid', 'refund failed: x', old::date, old::date, old, old,
       'failed', 7, true, null, null, false, false),
      ('psh_s16r5', u14, 'renewal', 'home', 'monthly', 99, 'paid', null, old::date, old::date, old, old,
       null, 0, false, null, 'resolved', false, false);
    set local session_replication_role = origin;

    perform billing.copy_from_old();
    perform billing.copy_from_old();                     -- a rerun: the copied refunds allow it
    insert into billing.switch_over (switched_at) values (now());

    -- fix 7
    a := (select id from billing.accounts where user_id = u8);
    s := pg_temp.sub(a);
    res := res || jsonb_build_object('l', 'S16 past due: the unpaid period ends at past_due_since',
      'p', s.status = 'past_due' and s.period_end = d8::timestamp at time zone tz
           and s.period_start = public.billing_step(d8, 'monthly', extract(day from d8)::int, -1)::timestamp at time zone tz,
      'd', s.period_start || ' to ' || s.period_end);
    select inv.* into bi from billing.invoices inv join billing.payment_attempts pa on pa.invoice = inv.id where pa.reference = 'psh_s16u8settle';
    res := res || jsonb_build_object('l', 'S16 ... the open settle page pays that period''s renewal bill',
      'p', bi.kind = 'renewal' and bi.subscription = s.id and bi.period_start = s.period_end and bi.status = 'open'
           and exists (select 1 from billing.payment_attempts where invoice = bi.id and gateway_response = 'copied: past due at the switch-over'),
      'd', bi.kind || ' ' || coalesce(bi.period_start::text, 'no period'));
    r := billing.apply_payment('psh_s16u8settle', jsonb_build_object('status', 'success', 'reference', 'psh_s16u8settle',
           'amount', 9900, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    s := pg_temp.sub(a);
    res := res || jsonb_build_object('l', 'S16 ... paid after the switch: active, the next date where the old billing had it',
      'p', r->>'action' = 'applied' and s.status = 'active'
           and s.period_end = public.billing_step(d8, 'monthly', extract(day from d8)::int, 1)::timestamp at time zone tz, 'd', r::text);
    -- fix 8
    s := pg_temp.sub((select id from billing.accounts where user_id = u9));
    res := res || jsonb_build_object('l', 'S16 billing day 31: the period before 30 Apr starts 31 Mar',
      'p', s.period_start = '2027-03-31 00:00+02' and s.period_end = '2027-04-30 00:00+02', 'd', s.period_start::text);
    -- fix 6
    a := (select id from billing.accounts where user_id = u10);
    r := billing.apply_payment('psh_s16u10', jsonb_build_object('status', 'reversed', 'reference', 'psh_s16u10'), now());
    res := res || jsonb_build_object('l', 'S16 an old paid renewal reversed after the switch: its period ends',
      'p', r->>'action' = 'plan_ended' and (pg_temp.sub(a)).status = 'ended', 'd', r::text);
    -- fixes 9, 10
    a := (select id from billing.accounts where user_id = u11);
    res := res || jsonb_build_object('l', 'S16 two open upgrades to the same plan: one bill',
      'p', (select count(distinct invoice) = 1 and count(*) = 2 from billing.payment_attempts where reference like 'psh_s16u11%'));
    res := res || jsonb_build_object('l', 'S16 ... with the seats open now and the plant it adds',
      'p', (select plants = '{990001611,990001612,990001613}' from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id
             where pa.reference = 'psh_s16u11b'));
    r := billing.apply_payment('psh_s16u11b', jsonb_build_object('status', 'success', 'reference', 'psh_s16u11b',
           'amount', 3000, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    res := res || jsonb_build_object('l', 'S16 ... paid: A and B still read, C starts',
      'p', r->>'action' = 'applied' and (select array_agg(plant order by plant) = '{990001611,990001612,990001613}'
                                          from billing.seats where account = a and closed_at is null), 'd', r::text);
    -- fix 11
    a := (select id from billing.accounts where user_id = u12);
    s := pg_temp.sub(a);
    res := res || jsonb_build_object('l', 'S16 an open switch to yearly: a yearly bill, never a yearly amount on a monthly one',
      'p', not exists (select 1 from billing.invoices where kind = 'upgrade' and interval = 'month' and amount_minor >= 99000)
           and (select i.interval = 'year' and i.amount_minor = 99000 from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id
                 where pa.reference = 'psh_s16u12'));
    r := billing.apply_payment('psh_s16u12', jsonb_build_object('status', 'success', 'reference', 'psh_s16u12',
           'amount', 99000, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    res := res || jsonb_build_object('l', 'S16 ... paid: Home yearly, to a year after its billing date',
      'p', r->>'action' = 'applied' and (pg_temp.sub(a)).interval = 'year' and (pg_temp.sub(a)).plan = 'home'
           and (pg_temp.sub(a)).period_end = (public.billing_step(nb12, 'yearly', extract(day from nb12)::int, 1))::timestamp at time zone tz
           and (pg_temp.sub(a)).billing_day = s.billing_day, 'd', r::text || ' ' || (pg_temp.sub(a)).period_end);
    a := (select id from billing.accounts where user_id = u13);
    r := billing.apply_payment('psh_s16u13', jsonb_build_object('status', 'success', 'reference', 'psh_s16u13',
           'amount', 196000, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    s := pg_temp.sub(a);
    res := res || jsonb_build_object('l', 'S16 an open upgrade to Family yearly, paid: Family yearly from the payment',
      'p', r->>'action' = 'applied' and s.plan = 'family' and s.interval = 'year' and s.period_start = now()
           and s.period_end = billing.add_period(now(), 'year', extract(day from now() at time zone tz)::int, tz)
           and s.amount_minor = 199000, 'd', r::text || ' ' || s.interval || ' ' || s.period_end);
    -- fix 5
    a := (select id from billing.accounts where user_id = u14);
    res := res || jsonb_build_object('l', 'S16 an old refund not done: owed again, retried',
      'p', exists (select 1 from billing.refunds where reference = 'psh_s16r1' and reason = 'stale' and status = 'due' and account = a)
           and billing.run(now())->'refunds' @> (select jsonb_build_array(jsonb_build_object('reference', 'psh_s16r1'))));
    res := res || jsonb_build_object('l', 'S16 a refund failed 7 times: left for hello@, not sent',
      'p', exists (select 1 from billing.refunds where reference = 'psh_s16r4' and reason = 'manual' and status = 'failed'));
    res := res || jsonb_build_object('l', 'S16 an open dispute, at any age: open on its try',
      'p', (select dispute_open from billing.payment_attempts where reference = 'psh_s16r2')
           and not exists (select 1 from billing.payment_attempts where reference = 'psh_s16r5'));   -- resolved, old: not copied
    res := res || jsonb_build_object('l', 'S16 a lost dispute still owed: owed on its bill',
      'p', (select amount_owed_minor = 9900 from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = 'psh_s16r3'));
    res := res || jsonb_build_object('l', 'S16 ... so the account may not be deleted',
      'p', pg_temp.st(a, now(), 'may_delete') = 'false' and pg_temp.st(a, now(), 'owed_minor') = '9900');
    res := res || jsonb_build_object('l', 'S16 no email for what the old billing already handled',
      'p', not exists (select 1 from billing.outbox o join billing.accounts ac on ac.id = o.account where ac.user_id = u14));
    raise exception 's16 undo';
  exception when others then
    if sqlerrm <> 's16 undo' then res := res || jsonb_build_object('l', 'S16 runs', 'p', false, 'd', sqlerrm); end if;
  end;
  for x in select * from jsonb_array_elements(res) loop
    perform pg_temp.ok(x->>'l', (x->>'p')::boolean, x->>'d');
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- S17 copy: verify 2 fixes, from what the old billing really writes. Rolled back like S15.
--   w1  plan ended (plan free, ended_at), a restart's card page still open; w1b ended on day 15
--       with its last saved-card renewal never answered (fix 1)
--   w2  a switch to yearly already paid (0138: next_period yearly, prepaid_on = next date);
--       w2c the same with a cancel booked in the paid year (fix 2)
--   w6  open upgrades monthly -> yearly: Family yearly (w6), Home yearly (w6b) (fix 6)
--   w7  a start Paystack refunded while still pending (0197) (fix 7)
--   w8  a renewal paid 200 days ago (fix 8)
--   w9  two open upgrades to Family with different plants and amounts (fix 9)
--   w14 past due with a failed renewal: the copy's counts (fix 14)
-- ---------------------------------------------------------------------------
do $$
declare
  tz constant text := 'Africa/Johannesburg';
  w1 uuid := gen_random_uuid(); w2 uuid := gen_random_uuid(); w2c uuid := gen_random_uuid(); w6 uuid := gen_random_uuid();
  w6b uuid := gen_random_uuid(); w7 uuid := gen_random_uuid(); w8 uuid := gen_random_uuid(); w9 uuid := gen_random_uuid();
  w14 uuid := gen_random_uuid(); w1b uuid := gen_random_uuid(); l1 uuid := gen_random_uuid(); l9 uuid := gen_random_uuid(); l7 uuid := gen_random_uuid();
  a uuid; s billing.subscriptions; bi billing.invoices; r jsonb; cp jsonb; res jsonb := '[]'; x jsonb;
  nb date := current_date + 10; bd int := extract(day from current_date + 10)::int; d14 date := current_date - 3;
  old timestamptz := now() - interval '300 days';
begin
  begin
    set local session_replication_role = replica;
    insert into auth.users (id, email, created_at)
    select u, 'copy-s17-' || n || '@state.test', old
      from unnest(array[w1, w2, w2c, w6, w6b, w7, w8, w9, w14, w1b]) with ordinality t (u, n);
    insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values
      (l1, w1, 's17w1', 'active', 'login'), (l9, w9, 's17w9', 'active', 'login'), (l7, w7, 's17w7', 'active', 'login');
    insert into public.plant_users (plant_id, user_id, account_id, plant_name, paused) values
      (990001701, w1, l1, 'W1', true), (990001771, w7, l7, 'W7', false),
      (990001791, w9, l9, 'A', false), (990001792, w9, l9, 'B', false), (990001793, w9, l9, 'C', true), (990001794, w9, l9, 'D', true);
    insert into private.plant_picks (user_id, plant_id, held, picked_at) values
      (w9, 990001791, true, old), (w9, 990001792, true, old), (w9, 990001793, false, old), (w9, 990001794, false, old);
    -- w1: Home ended 10 days ago (0212: plan free, ended_at); its last renewal paid; a restart page open
    insert into private.billing (user_id, plan, state, ended_at, created_at) values (w1, 'free', 'active', now() - interval '10 days', old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at, plants) values
      ('psh_s17w1paid', w1, 'renewal', 'home', 'monthly', 99, 'paid', current_date - 40, current_date - 40, now() - interval '40 days', now() - interval '40 days', null),
      ('psh_s17w1start', w1, 'start', 'home', 'monthly', 99, 'pending', current_date, current_date, now() - interval '10 minutes', null, '{990001701}');
    insert into private.billing (user_id, plan, state, ended_at, created_at) values (w1b, 'free', 'active', now() - interval '2 days', old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at, tried_on) values
      ('psh_s17w1bpaid', w1b, 'renewal', 'home', 'monthly', 99, 'paid', current_date - 47, current_date - 47, now() - interval '47 days', now() - interval '47 days', current_date - 47),
      ('psh_s17w1bren', w1b, 'renewal', 'home', 'monthly', 99, 'pending', current_date - 17, current_date - 3, now() - interval '3 days', null, current_date - 3);
    -- w2, w2c: Home monthly, the yearly switch paid (0145's switch branch); w2c cancelled in the paid year
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, next_period, next_plan, prepaid_on, state, created_at) values
      (w2, 'home', 'monthly', bd, nb, 'yearly', null, nb, 'active', old),
      (w2c, 'home', 'monthly', bd, nb, 'yearly', 'free', nb, 'active', old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, added, extra_plants, amount, status, due_on, created_on, created_at, settled_at, billing_date) values
      ('psh_s17w2sw', w2, 'switch', 'home', 'yearly', 0, 0, 990, 'paid', current_date - 5, current_date - 5, now() - interval '5 days', now() - interval '5 days', nb),
      ('psh_s17w2csw', w2c, 'switch', 'home', 'yearly', 0, 0, 990, 'paid', current_date - 5, current_date - 5, now() - interval '5 days', now() - interval '5 days', nb);
    -- w6: an open upgrade to Family yearly; w6b: an open switch to Home yearly
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, created_at) values
      (w6, 'home', 'monthly', bd, nb, 'active', old), (w6b, 'home', 'monthly', bd, nb, 'active', old),
      (w9, 'home', 'monthly', bd, nb, 'active', old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, added, extra_plants, amount, status, due_on, created_on, created_at, billing_date) values
      ('psh_s17w6', w6, 'upgrade', 'family', 'yearly', 0, 0, 1960, 'pending', current_date, current_date, now() - interval '10 minutes', nb),
      ('psh_s17w6b', w6b, 'switch', 'home', 'yearly', 0, 0, 990, 'pending', current_date, current_date, now() - interval '10 minutes', nb);
    -- w7: a start page Paystack refunded before it reported the payment (billing_charge_refund_event)
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, plants,
                                         refunds, refund_status, refunded_at, refunded_cents) values
      ('psh_s17w7', w7, 'start', 'home', 'monthly', 99, 'pending', current_date, current_date, now() - interval '30 minutes', '{990001771}',
       '{"RF_s17w7": 9900}', 'done', now() - interval '5 minutes', 9900);
    -- w8: a renewal settled long ago
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at) values
      ('psh_s17w8', w8, 'renewal', 'home', 'monthly', 99, 'paid', (now() - interval '200 days')::date, (now() - interval '200 days')::date,
       now() - interval '200 days', now() - interval '200 days');
    -- w9: Home with A, B read; a Family page adding C, then one adding C and D a day's proration later
    insert into private.billing_charges (reference, user_id, kind, plan, period, added, extra_plants, plants, amount, status, due_on, created_on, created_at, billing_date) values
      ('psh_s17w9a', w9, 'upgrade', 'family', 'monthly', 0, 0, '{990001793}', 30, 'pending', current_date, current_date, now() - interval '20 minutes', nb),
      ('psh_s17w9b', w9, 'upgrade', 'family', 'monthly', 0, 0, '{990001793,990001794}', 28, 'pending', current_date, current_date, now() - interval '10 minutes', nb);
    -- w14: past due (the old run moved the date on), its renewal failed
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, past_due_since, created_at)
    values (w14, 'home', 'monthly', extract(day from d14)::int, public.billing_step(d14, 'monthly', extract(day from d14)::int, 1), 'past_due', d14, old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, error, due_on, created_on, created_at, settled_at, tried_on) values
      ('psh_s17w14', w14, 'renewal', 'home', 'monthly', 99, 'failed', 'Insufficient Funds', d14, d14, now() - interval '3 days', now() - interval '3 days', d14);
    set local session_replication_role = origin;

    perform billing.copy_from_old();
    cp := billing.copy_from_old();
    insert into billing.switch_over (switched_at) values (now());

    -- fix 14 (before any payment moves a try)
    res := res || jsonb_build_object('l', 'S17 the copy counts its own past-due tries apart from failed old charges',
      'p', (cp->>'past_due_seeded')::int = (select count(*) from billing.subscriptions where status = 'past_due')
           and (cp->>'old_charges')::int + (cp->>'past_due_seeded')::int = (select count(*) from billing.payment_attempts),
      'd', cp::text);
    -- fix 1
    a := (select id from billing.accounts where user_id = w1);
    res := res || jsonb_build_object('l', 'S17 plan ended, a restart page open: copied, its plan row ended',
      'p', (pg_temp.sub(a)).status = 'ended');
    r := billing.apply_payment('psh_s17w1start', jsonb_build_object('status', 'success', 'reference', 'psh_s17w1start',
           'amount', 9900, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    res := res || jsonb_build_object('l', 'S17 ... paid after the switch: Home again',
      'p', r->>'action' = 'applied' and r->>'kind' = 'purchase' and (pg_temp.sub(a)).status = 'active', 'd', r::text);
    a := (select id from billing.accounts where user_id = w1b);
    r := billing.apply_payment('psh_s17w1bren', jsonb_build_object('status', 'success', 'reference', 'psh_s17w1bren',
           'amount', 9900, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    res := res || jsonb_build_object('l', 'S17 an ended plan''s open renewal: copied, paid after the switch is refunded',
      'p', (pg_temp.sub(a)).status = 'ended' and r->>'action' = 'refund', 'd', r::text);
    -- fix 2
    a := (select id from billing.accounts where user_id = w2);
    s := pg_temp.sub(a);
    res := res || jsonb_build_object('l', 'S17 a paid switch to yearly: Home yearly to a year after the billing date',
      'p', s.status = 'active' and s.interval = 'year' and s.plan = 'home'
           and s.period_end = public.billing_step(nb, 'yearly', bd, 1)::timestamp at time zone tz
           and (select interval = 'year' and amount_minor = s.amount_minor from billing.prices where id = s.price)
           and s.next_price is null and not s.cancel_at_period_end,
      'd', s.interval || ' ' || s.period_end || ' ' || coalesce(s.next_price::text, 'no next'));
    a := (select id from billing.accounts where user_id = w2c);
    s := pg_temp.sub(a);
    res := res || jsonb_build_object('l', 'S17 ... a cancel booked in the paid year ends at the year''s end',
      'p', s.interval = 'year' and s.cancel_at_period_end and s.next_price is null
           and s.period_end = public.billing_step(nb, 'yearly', bd, 1)::timestamp at time zone tz,
      'd', s.interval || ' ' || s.period_end);
    -- fix 6
    a := (select id from billing.accounts where user_id = w6);
    r := billing.apply_payment('psh_s17w6', jsonb_build_object('status', 'success', 'reference', 'psh_s17w6',
           'amount', 196000, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    s := pg_temp.sub(a);
    select i.* into bi from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = 'psh_s17w6';
    res := res || jsonb_build_object('l', 'S17 a copied upgrade to Family yearly: its bill names the yearly period',
      'p', r->>'action' = 'applied' and s.interval = 'year' and bi.period_start = s.period_start and bi.period_end = s.period_end,
      'd', bi.period_start || ' to ' || bi.period_end || ' vs ' || s.period_start || ' to ' || s.period_end);
    a := (select id from billing.accounts where user_id = w6b);
    r := billing.apply_payment('psh_s17w6b', jsonb_build_object('status', 'success', 'reference', 'psh_s17w6b',
           'amount', 99000, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    s := pg_temp.sub(a);
    select i.* into bi from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = 'psh_s17w6b';
    res := res || jsonb_build_object('l', 'S17 ... a copied switch to Home yearly: the same',
      'p', r->>'action' = 'applied' and s.interval = 'year' and bi.period_start = s.period_start and bi.period_end = s.period_end,
      'd', bi.period_start || ' to ' || bi.period_end || ' vs ' || s.period_start || ' to ' || s.period_end);
    -- fix 7
    a := (select id from billing.accounts where user_id = w7);
    res := res || jsonb_build_object('l', 'S17 a refund on a still-pending old charge is copied',
      'p', exists (select 1 from billing.refunds where reference = 'psh_s17w7' and status = 'processed'));
    r := billing.apply_payment('psh_s17w7', jsonb_build_object('status', 'success', 'reference', 'psh_s17w7',
           'amount', 9900, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    res := res || jsonb_build_object('l', 'S17 ... the success that follows is not applied, and no second refund',
      'p', r->>'action' = 'refund' and r->>'reason' = 'stale' and not exists (select 1 from billing.subscriptions where account = a)
           and (select count(*) = 1 from billing.refunds where reference = 'psh_s17w7'), 'd', r::text);
    -- verify 3 fix 2: the refund already on record is not handed back, so nothing is sent again
    res := res || jsonb_build_object('l', 'S17 ... and no refund id back to send', 'p', r ? 'refund' and r->'refund' = 'null', 'd', r::text);
    -- fix 8
    r := billing.apply_payment('psh_s17w8', jsonb_build_object('status', 'success', 'reference', 'psh_s17w8',
           'amount', 9900, 'currency', 'ZAR', 'gateway_response', 'Approved'), now());
    res := res || jsonb_build_object('l', 'S17 an old paid reference past 120 days sent again: already applied, not refunded',
      'p', r->>'action' = 'again' and not exists (select 1 from billing.refunds where reference = 'psh_s17w8'), 'd', r::text);
    -- fix 9
    a := (select id from billing.accounts where user_id = w9);
    res := res || jsonb_build_object('l', 'S17 two open upgrades that differ: the older bill void, the newer open',
      'p', (select i.status = 'void' from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = 'psh_s17w9a')
           and (select i.status = 'open' and i.amount_minor = 2800 and i.plants = '{990001791,990001792,990001793,990001794}'
                  from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = 'psh_s17w9b'));
    r := billing.apply_payment('psh_s17w9a', jsonb_build_object('status', 'success', 'reference', 'psh_s17w9a',
           'amount', 3000, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    res := res || jsonb_build_object('l', 'S17 ... the older page paid: refunded', 'p', r->>'action' = 'refund', 'd', r::text);
    r := billing.apply_payment('psh_s17w9b', jsonb_build_object('status', 'success', 'reference', 'psh_s17w9b',
           'amount', 2800, 'currency', 'ZAR', 'gateway_response', 'Approved', 'paid_at', now()), now());
    res := res || jsonb_build_object('l', 'S17 ... the newer page paid: Family with A, B, C and D',
      'p', r->>'action' = 'applied' and (pg_temp.sub(a)).plan = 'family'
           and (select array_agg(plant order by plant) = '{990001791,990001792,990001793,990001794}'
                  from billing.seats where account = a and closed_at is null), 'd', r::text);
    -- fix 2: nothing is charged on the billing date of the paid year
    r := billing.run((nb + 1)::timestamp at time zone tz + interval '10 hours');
    res := res || jsonb_build_object('l', 'S17 the paid year: no charge on its billing date',
      'p', not exists (select 1 from jsonb_array_elements(r->'charges') c join billing.invoices i on i.id = (c->>'invoice')::uuid
                        join billing.accounts ac on ac.id = i.account where ac.user_id in (w2, w2c)), 'd', r::text);
    raise exception 's17 undo';
  exception when others then
    if sqlerrm <> 's17 undo' then res := res || jsonb_build_object('l', 'S17 runs', 'p', false, 'd', sqlerrm); end if;
  end;
  for x in select * from jsonb_array_elements(res) loop
    perform pg_temp.ok(x->>'l', (x->>'p')::boolean, x->>'d');
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- S18 copy: verify 3 fixes 4-6. Rolled back like S15.
--   y4  a failed refund with no error text on a paid start: by hand, never sent automatically (fix 4)
--   y5  a paid switch to yearly: the year starts on its billing date; an upgrade now charges
--       that year's difference, no more (fix 5)
--   y6  the same, its switch payment disputed and lost after the switch: the paid year ends (fix 6)
--   y6b a renewal paid 200 days ago (kept only as a reference) disputed after the switch: the
--       open dispute blocks the delete, a lost one is owed (fix 6)
-- ---------------------------------------------------------------------------
do $$
declare
  tz constant text := 'Africa/Johannesburg';
  y4 uuid := gen_random_uuid(); y5 uuid := gen_random_uuid(); y6 uuid := gen_random_uuid(); y6b uuid := gen_random_uuid();
  a uuid; s billing.subscriptions; bi billing.invoices; r jsonb; res jsonb := '[]'; x jsonb; hy int; fy int;
  nb date := current_date + 10; bd int := extract(day from current_date + 10)::int;
  old timestamptz := now() - interval '300 days';
begin
  begin
    set local session_replication_role = replica;
    insert into auth.users (id, email, created_at)
    select u, 'copy-s18-' || n || '@state.test', old from unnest(array[y4, y5, y6, y6b]) with ordinality t (u, n);
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at,
                                         refund_status, refund_tries) values
      ('psh_s18y4', y4, 'start', 'home', 'monthly', 99, 'paid', current_date - 5, current_date - 5, now() - interval '5 days',
       now() - interval '5 days', 'failed', 1);
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, next_period, prepaid_on, state, created_at) values
      (y5, 'home', 'monthly', bd, nb, 'yearly', nb, 'active', old), (y6, 'home', 'monthly', bd, nb, 'yearly', nb, 'active', old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, added, extra_plants, amount, status, due_on, created_on, created_at, settled_at, billing_date) values
      ('psh_s18y5sw', y5, 'switch', 'home', 'yearly', 0, 0, 990, 'paid', current_date - 5, current_date - 5, now() - interval '5 days', now() - interval '5 days', nb),
      ('psh_s18y6sw', y6, 'switch', 'home', 'yearly', 0, 0, 990, 'paid', current_date - 5, current_date - 5, now() - interval '5 days', now() - interval '5 days', nb);
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at) values
      ('psh_s18y6b', y6b, 'renewal', 'home', 'monthly', 99, 'paid', (now() - interval '200 days')::date, (now() - interval '200 days')::date,
       now() - interval '200 days', now() - interval '200 days');
    set local session_replication_role = origin;

    perform billing.copy_from_old();
    insert into billing.switch_over (switched_at) values (now()) on conflict do nothing;

    -- fix 4
    res := res || jsonb_build_object('l', 'S18 a failed refund with no error text: by hand, not sent',
      'p', (select reason = 'manual' and status = 'failed' from billing.refunds where reference = 'psh_s18y4'),
      'd', (select reason || ' ' || status from billing.refunds where reference = 'psh_s18y4'));
    -- fix 5
    a := (select id from billing.accounts where user_id = y5);
    s := pg_temp.sub(a);
    res := res || jsonb_build_object('l', 'S18 a paid year starts on its billing date and ends a year later',
      'p', s.period_start = nb::timestamp at time zone tz
           and s.period_end = public.billing_step(nb, 'yearly', bd, 1)::timestamp at time zone tz,
      'd', s.period_start || ' to ' || s.period_end);
    hy := (select amount_minor from billing.prices where id = s.price);
    fy := (billing.price_keeping_offer('family', 'ZA', 'year', s.offer, now())).amount_minor;
    r := billing.upgrade(a, 'family', 0, '{}', now());
    res := res || jsonb_build_object('l', 'S18 ... an upgrade before it starts charges that year''s difference, no more',
      'p', (r->>'amount_minor')::int = fy - hy, 'd', r::text || ' want ' || (fy - hy));
    -- fix 6
    a := (select id from billing.accounts where user_id = y6);
    select i.* into bi from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = 'psh_s18y6sw';
    res := res || jsonb_build_object('l', 'S18 the paid switch''s bill is the paid year',
      'p', bi.subscription = (pg_temp.sub(a)).id and bi.period_start = (pg_temp.sub(a)).period_start
           and bi.period_end = (pg_temp.sub(a)).period_end, 'd', coalesce(bi.period_start::text, 'no period'));
    r := billing.record_dispute('psh_s18y6sw', 'charge.dispute.resolve', 'resolved', true, 99000, now(), 'D_s18y6');
    res := res || jsonb_build_object('l', 'S18 ... lost after the switch: the paid year ends',
      'p', r->>'action' = 'plan_ended' and (pg_temp.sub(a)).status = 'ended', 'd', r::text);
    a := (select id from billing.accounts where user_id = y6b);
    r := billing.record_dispute('psh_s18y6b', 'charge.dispute.create', 'awaiting-merchant-feedback', false, null, now(), 'D_s18y6b');
    res := res || jsonb_build_object('l', 'S18 an old paid reference disputed: its bill and try come back',
      'p', r->>'action' = 'recorded' and exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
             where pa.reference = 'psh_s18y6b' and pa.dispute_open and i.account = a and i.status = 'paid' and i.amount_minor = 9900),
      'd', r::text);
    begin
      perform billing.delete_account(a, now());
      res := res || jsonb_build_object('l', 'S18 ... the open dispute blocks the delete', 'p', false, 'd', 'deleted');
    exception when others then
      res := res || jsonb_build_object('l', 'S18 ... the open dispute blocks the delete', 'p', sqlerrm like '%dispute is open%', 'd', sqlerrm);
    end;
    r := billing.record_dispute('psh_s18y6b', 'charge.dispute.resolve', 'resolved', true, 9900, now(), 'D_s18y6b');
    res := res || jsonb_build_object('l', 'S18 ... lost: the amount is owed',
      'p', r->>'action' = 'owed' and (select i.amount_owed_minor = 9900 from billing.invoices i join billing.payment_attempts pa
             on pa.invoice = i.id where pa.reference = 'psh_s18y6b'), 'd', r::text);
    raise exception 's18 undo';
  exception when others then
    if sqlerrm <> 's18 undo' then res := res || jsonb_build_object('l', 'S18 runs', 'p', false, 'd', sqlerrm); end if;
  end;
  for x in select * from jsonb_array_elements(res) loop
    perform pg_temp.ok(x->>'l', (x->>'p')::boolean, x->>'d');
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- S19 copy: verify 4 fix 1. Rolled back like S15.
--   z1  a yearly plan whose renewal was paid 200 days ago: copied, on that plan and year;
--       lost in a dispute after the switch, the year ends
--   z2  a yearly Family plan upgraded 150 days ago: the upgrade is on that year; reversed, it ends
--   z3  a refund asked 200 days ago on a renewal, no error text: copied, still asked
-- ---------------------------------------------------------------------------
do $$
declare
  tz constant text := 'Africa/Johannesburg';
  z1 uuid := gen_random_uuid(); z2 uuid := gen_random_uuid(); z3 uuid := gen_random_uuid();
  a uuid; bi billing.invoices; r jsonb; res jsonb := '[]'; x jsonb;
  nb date := current_date + 165; bd int := extract(day from current_date + 165)::int;
  ys date := public.billing_step(current_date + 165, 'yearly', extract(day from current_date + 165)::int, -1);
  old timestamptz := now() - interval '400 days';
begin
  begin
    set local session_replication_role = replica;
    insert into auth.users (id, email, created_at)
    select u, 'copy-s19-' || n || '@state.test', old from unnest(array[z1, z2, z3]) with ordinality t (u, n);
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, created_at) values
      (z1, 'home', 'yearly', bd, nb, 'active', old), (z2, 'family', 'yearly', bd, nb, 'active', old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at) values
      ('psh_s19z1', z1, 'renewal', 'home', 'yearly', 990, 'paid', ys, ys, ys::timestamp at time zone tz + interval '1 hour',
       ys::timestamp at time zone tz + interval '1 hour'),
      ('psh_s19z2', z2, 'upgrade', 'family', 'yearly', 500, 'paid', current_date - 150, current_date - 150,
       now() - interval '150 days', now() - interval '150 days');
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at,
                                         refund_status) values
      ('psh_s19z3', z3, 'renewal', 'home', 'monthly', 99, 'paid', (now() - interval '200 days')::date, (now() - interval '200 days')::date,
       now() - interval '200 days', now() - interval '200 days', 'asked');
    set local session_replication_role = origin;

    perform billing.copy_from_old();
    insert into billing.switch_over (switched_at) values (now()) on conflict do nothing;

    a := (select id from billing.accounts where user_id = z1);
    select i.* into bi from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = 'psh_s19z1';
    res := res || jsonb_build_object('l', 'S19 a yearly renewal paid 200 days ago: on that plan and year',
      'p', bi.subscription = (pg_temp.sub(a)).id and bi.period_start = (pg_temp.sub(a)).period_start
           and bi.period_end = (pg_temp.sub(a)).period_end, 'd', coalesce(bi.period_start::text, 'not copied'));
    r := billing.record_dispute('psh_s19z1', 'charge.dispute.resolve', 'resolved', true, 99000, now(), 'D_s19z1');
    res := res || jsonb_build_object('l', 'S19 ... lost in a dispute: the year ends',
      'p', r->>'action' = 'plan_ended' and (pg_temp.sub(a)).status = 'ended', 'd', r::text);
    a := (select id from billing.accounts where user_id = z2);
    select i.* into bi from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = 'psh_s19z2';
    res := res || jsonb_build_object('l', 'S19 an upgrade paid 150 days into a yearly plan: on that year',
      'p', bi.subscription = (pg_temp.sub(a)).id and bi.period_start = (pg_temp.sub(a)).period_start,
      'd', coalesce(bi.period_start::text, 'not copied'));
    r := billing.apply_payment('psh_s19z2', jsonb_build_object('status', 'reversed', 'reference', 'psh_s19z2'), now());
    res := res || jsonb_build_object('l', 'S19 ... reversed: the year ends',
      'p', r->>'action' = 'plan_ended' and (pg_temp.sub(a)).status = 'ended', 'd', r::text);
    res := res || jsonb_build_object('l', 'S19 a refund asked 200 days ago, no error text: copied, still asked',
      'p', (select status = 'pending' from billing.refunds where reference = 'psh_s19z3'),
      'd', coalesce((select reason || ' ' || status from billing.refunds where reference = 'psh_s19z3'), 'not copied'));
    raise exception 's19 undo';
  exception when others then
    if sqlerrm <> 's19 undo' then res := res || jsonb_build_object('l', 'S19 runs', 'p', false, 'd', sqlerrm); end if;
  end;
  for x in select * from jsonb_array_elements(res) loop
    perform pg_temp.ok(x->>'l', (x->>'p')::boolean, x->>'d');
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- S20 copy: verify 5 fixes 1, 3, 5. Rolled back like S15.
--   v1  a yearly start paid 200 days ago, its card page opened at 23:58 and paid at 00:02:
--       the year starts the day it was paid; copied, on that plan and year (fix 1)
--   v3  a yearly renewal pending at the freeze: the renewal paid a year before it is copied (fix 3)
--   v5  a monthly-to-yearly switch paid 200 days ago, on its billing date: copied, on that year (fix 5)
-- ---------------------------------------------------------------------------
do $$
declare
  tz constant text := 'Africa/Johannesburg';
  v1 uuid := gen_random_uuid(); v3 uuid := gen_random_uuid(); v5 uuid := gen_random_uuid();
  a uuid; bi billing.invoices; res jsonb := '[]'; x jsonb;
  paid_day date := current_date - 200;                       -- the day after the page opened
  nb1 date := public.billing_step(current_date - 200, 'yearly', extract(day from current_date - 200)::int, 1);
  due3 date := current_date - 2;                             -- the pending renewal
  ys5 date := current_date - 200; nb5 date := public.billing_step(current_date - 200, 'yearly', extract(day from current_date - 200)::int, 1);
  old timestamptz := now() - interval '500 days';
begin
  begin
    set local session_replication_role = replica;
    insert into auth.users (id, email, created_at)
    select u, 'copy-s20-' || n || '@state.test', old from unnest(array[v1, v3, v5]) with ordinality t (u, n);
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, created_at) values
      (v1, 'home', 'yearly', extract(day from paid_day)::int, nb1, 'active', old),
      (v3, 'home', 'yearly', extract(day from due3)::int,
       public.billing_step(due3, 'yearly', extract(day from due3)::int, 1), 'active', old),
      (v5, 'home', 'yearly', extract(day from ys5)::int, nb5, 'active', old);
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at, billing_date) values
      ('psh_s20v1', v1, 'start', 'home', 'yearly', 990, 'paid', paid_day - 1, paid_day - 1,
       (paid_day - 1)::timestamp at time zone tz + interval '23 hours 58 minutes',
       paid_day::timestamp at time zone tz + interval '2 minutes', null),
      ('psh_s20v3old', v3, 'renewal', 'home', 'yearly', 990, 'paid', (due3 - interval '1 year')::date, (due3 - interval '1 year')::date,
       (due3 - interval '1 year')::timestamp at time zone tz + interval '1 hour',
       (due3 - interval '1 year')::timestamp at time zone tz + interval '1 hour', null),
      ('psh_s20v5', v5, 'switch', 'home', 'yearly', 990, 'paid', ys5 - 10, ys5 - 10,
       (ys5 - 10)::timestamp at time zone tz + interval '9 hours', (ys5 - 10)::timestamp at time zone tz + interval '9 hours', ys5);
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at) values
      ('psh_s20v3', v3, 'renewal', 'home', 'yearly', 990, 'pending', due3, due3, due3::timestamp at time zone tz + interval '1 hour');
    set local session_replication_role = origin;

    perform billing.copy_from_old();
    insert into billing.switch_over (switched_at) values (now()) on conflict do nothing;

    a := (select id from billing.accounts where user_id = v1);
    select i.* into bi from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = 'psh_s20v1';
    res := res || jsonb_build_object('l', 'S20 a yearly start paid across midnight 200 days ago: on that plan and year',
      'p', bi.subscription = (pg_temp.sub(a)).id and bi.period_start = (pg_temp.sub(a)).period_start
           and bi.period_start = paid_day::timestamp at time zone tz and bi.period_end = (pg_temp.sub(a)).period_end,
      'd', coalesce(bi.period_start::text || ' to ' || bi.period_end::text, 'not copied'));
    res := res || jsonb_build_object('l', 'S20 a yearly renewal pending at the freeze: the one paid a year before is copied',
      'p', exists (select 1 from billing.payment_attempts where reference = 'psh_s20v3old' and status = 'success'),
      'd', coalesce((select status from billing.payment_attempts where reference = 'psh_s20v3old'), 'not copied'));
    a := (select id from billing.accounts where user_id = v5);
    select i.* into bi from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = 'psh_s20v5';
    res := res || jsonb_build_object('l', 'S20 a switch to yearly paid 200 days ago: on that plan and year',
      'p', bi.subscription = (pg_temp.sub(a)).id and bi.period_start = (pg_temp.sub(a)).period_start
           and bi.period_end = (pg_temp.sub(a)).period_end,
      'd', coalesce(bi.period_start::text, 'not copied'));
    raise exception 's20 undo';
  exception when others then
    if sqlerrm <> 's20 undo' then res := res || jsonb_build_object('l', 'S20 runs', 'p', false, 'd', sqlerrm); end if;
  end;
  for x in select * from jsonb_array_elements(res) loop
    perform pg_temp.ok(x->>'l', (x->>'p')::boolean, x->>'d');
  end loop;
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
-- P2 one open purchase bill per account; closing the card page and trying again
--    lands on the same page; a new checkout replaces an open page (no wait);
--    a late success on a replaced bill; the same bill paid twice
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('p2'); b uuid := pg_temp.acct('p2b'); c uuid := pg_temp.acct('p2c');
        i1 uuid; i2 uuid; i3 uuid; r1 text; r1b text; r2 text; r jsonb;
begin
  perform pg_temp.link(a, 'p2', '{990010201,990010202}', pg_temp.t(0));
  i1 := (billing.start_checkout(a, 'home', 'month', 0, '{990010201}', pg_temp.t(0))->>'invoice')::uuid;
  r1 := billing.begin_attempt(i1, 'card_page', pg_temp.t(0))->>'reference';
  perform billing.attempt_page(r1, 'https://checkout.paystack.com/p2a');
  perform pg_temp.eq('P2 the same checkout again: the same bill',
    billing.start_checkout(a, 'home', 'month', 0, '{990010201}', pg_temp.t(0))->>'invoice', i1::text);
  r := billing.begin_attempt(i1, 'card_page', pg_temp.t(0) + interval '5 minutes');
  perform pg_temp.eq('P2 page closed, tried again: the same page', r->>'url', 'https://checkout.paystack.com/p2a');
  perform pg_temp.eq('P2 ... and the same try', r->>'reference', r1);
  perform pg_temp.ok('P2 a page link is only stored as https', billing.attempt_page(r1, 'javascript:x') is null);
  -- the page lease runs out: verified first; Paystack says abandoned: void, then a new page
  perform pg_temp.ok('P2 lease over: verify first', billing.begin_attempt(i1, 'card_page', pg_temp.t(0) + interval '61 minutes') ? 'verify');
  r := pg_temp.answer(r1, 'abandoned', pg_temp.t(0) + interval '62 minutes');
  perform pg_temp.eq('P2 abandoned page: void', r->>'action', 'void');
  r1b := billing.begin_attempt(i1, 'card_page', pg_temp.t(0) + interval '62 minutes')->>'reference';
  perform pg_temp.ok('P2 abandoned: a new page', r1b is not null and r1b <> r1);
  -- another checkout while that page is open: no wait; the open page is replaced, never
  -- handed back, but stays pending until Paystack says it cannot pay (final fix 1)
  i2 := (billing.start_checkout(a, 'family', 'month', 0, '{990010201,990010202}', pg_temp.t(0) + interval '63 minutes')->>'invoice')::uuid;
  perform pg_temp.ok('P2 a new checkout replaces the open bill', i2 <> i1 and (select status = 'void' from billing.invoices where id = i1));
  perform pg_temp.ok('P2 its open page replaced, still pending', (select status = 'pending' and replaced_at is not null
    from billing.payment_attempts where reference = r1b));
  r2 := billing.begin_attempt(i2, 'card_page', pg_temp.t(0) + interval '63 minutes')->>'reference';
  r := pg_temp.answer(r2, 'ok', pg_temp.t(0) + interval '64 minutes');
  perform pg_temp.eq('P2 paid: applied', r->>'action', 'applied');
  r := pg_temp.answer(r1b, 'ok', pg_temp.t(0) + interval '65 minutes');
  perform pg_temp.eq('P2 late success on the replaced bill: refunded', r->>'action', 'refund');
  perform pg_temp.eq('P2 replaced bill: stale', r->>'reason', 'stale');
  -- the offer gone: a new bill at list price, not the old launch-price one
  perform pg_temp.link(c, 'p2c', '{990010211}', pg_temp.t(0));
  i3 := (billing.start_checkout(c, 'home', 'month', 0, '{990010211}', pg_temp.t(0))->>'invoice')::uuid;
  update billing.offers set valid_until = pg_temp.t(0) - interval '1 day' where code = 'launch';
  perform pg_temp.ok('P2 offer gone: not the old launch-price bill',
    (billing.start_checkout(c, 'home', 'month', 0, '{990010211}', pg_temp.t(0))->>'invoice')::uuid <> i3);
  update billing.offers set valid_until = null where code = 'launch';
  perform pg_temp.eq('P2 the paid choice stands', pg_temp.st(a, pg_temp.t(1), 'plan'), 'family');
  perform pg_temp.ok('P2 one plan', (select count(*) = 1 from billing.subscriptions where account = a));
  perform pg_temp.ok('P2 refund owed against the try', exists (select 1 from billing.refunds r join billing.payment_attempts pa on pa.id = r.attempt
    where pa.reference = r1b and r.reason = 'stale' and r.status = 'due'));
  -- the same bill paid twice (a try let go, then paid late): the second is a duplicate
  perform pg_temp.link(b, 'p2b', '{990010203}', pg_temp.t(0));
  i1 := (billing.start_checkout(b, 'home', 'month', 0, '{990010203}', pg_temp.t(0))->>'invoice')::uuid;
  r1 := billing.begin_attempt(i1, 'card_page', pg_temp.t(0))->>'reference';
  perform pg_temp.answer(r1, 'abandoned', pg_temp.t(0));
  r2 := billing.begin_attempt(i1, 'card_page', pg_temp.t(0))->>'reference';
  perform pg_temp.answer(r2, 'ok', pg_temp.t(0));
  r := pg_temp.answer(r1, 'ok', pg_temp.t(0));
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
  perform pg_temp.eq('P3 abandoned page: void, not a decline', r->>'action', 'void');
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
  -- the window starts on the bill's due date, not the job's first run (review fix 6)
  perform pg_temp.eqt('P7 window starts at the due date', pg_temp.st(a, pe + interval '8 days', 'past_due_since'), pe);
  perform pg_temp.eq('P7 same run time: no second try', pg_temp.job(a, pe + interval '8 days 1 minute', 'fail'), null);
  perform pg_temp.eq('P7 the late try was the day-7 one: none on day 10', pg_temp.job(a, pe + interval '10 days', 'fail'), null);
  perform pg_temp.ok('P7 day 14: one try', pg_temp.job(a, pe + interval '14 days', 'fail') is not null);
  perform pg_temp.eq('P7 days never fire together', pg_temp.job(a, pe + interval '14 days 1 minute', 'fail'), null);
  perform pg_temp.eq('P7 the purchase and two renewal tries', pg_temp.tries(a)::text, '3');
  perform pg_temp.eq('P7 day 15 from the due date: ended', pg_temp.st(a, pe + interval '15 days', 'state'), 'ended');

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

-- ===========================================================================
-- Phase 2 review fixes (each block fails without its fix)
-- ===========================================================================
-- a paying account with a saved card; returns its plan's period end
create function pg_temp.member(p_acc uuid, p_name text, p_plant bigint, p_plan text default 'home') returns timestamptz language plpgsql as $$
begin
  perform pg_temp.link(p_acc, p_name, array[p_plant], pg_temp.t(0));
  perform pg_temp.buy(p_acc, p_plan, 'month', array[p_plant], pg_temp.t(0), 'AUTH_' || p_name);
  return (pg_temp.sub(p_acc)).period_end;
end $$;

-- F1 a renewal that never gets a clear answer still ends on day 15; an open card page holds
--    the retry until Paystack calls it abandoned (phase 3 fix 1); a bank challenge Paystack
--    still calls pending after 24 h fails, and the job never fails it unasked (fix 2); a late
--    "pending" on a try already settled changes nothing
do $$
declare a uuid := pg_temp.acct('f1a'); b uuid := pg_temp.acct('f1b'); c uuid := pg_temp.acct('f1c'); d uuid := pg_temp.acct('f1d');
        pe timestamptz; ref text; inv uuid;
begin
  pe := pg_temp.member(a, 'f1a', 990020101);
  ref := pg_temp.job(a, pe);                          -- written, no answer yet
  perform billing.run(pe + interval '1 hour');
  perform pg_temp.eq('F1 a written try with its lease over gets time to verify', pg_temp.st(a, pe + interval '1 hour', 'state'), 'active');
  perform pg_temp.answer(ref, 'unknown', pe + interval '1 hour');
  perform pg_temp.eq('F1 unknown day 0: active until the job looks again', pg_temp.st(a, pe + interval '1 day', 'state'), 'active');
  perform billing.run(pe + interval '1 day');
  perform pg_temp.eq('F1 unknown day 0, lease over: the window starts', pg_temp.st(a, pe + interval '1 day', 'state'), 'past_due');
  perform pg_temp.eqt('F1 from the due date', pg_temp.st(a, pe + interval '1 day', 'past_due_since'), pe);
  perform billing.run(pe + interval '15 days 1 hour');
  perform pg_temp.eq('F1 never answered: ended on day 15', (pg_temp.sub(a)).status, 'ended');

  pe := pg_temp.member(b, 'f1b', 990020102);
  ref := pg_temp.job(b, pe, 'fail');
  inv := (billing.pay_now(b, pe + interval '3 days')->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pe + interval '3 days')->>'reference';
  perform pg_temp.ok('F1 owner''s card page open: no day-3 charge on top of it', pg_temp.job(b, pe + interval '3 days 1 minute') is null);
  perform pg_temp.answer(ref, 'abandoned', pe + interval '3 days 2 hours');
  perform pg_temp.ok('F1 page abandoned: the day-3 retry runs', pg_temp.job(b, pe + interval '3 days 3 hours') is not null);

  pe := pg_temp.member(c, 'f1c', 990020103);
  ref := pg_temp.job(c, pe, 'pending');
  perform billing.run(pe + interval '25 hours');
  perform pg_temp.eq('F1 the job does not fail a pending try unasked', (select status from billing.payment_attempts where reference = ref), 'pending');
  perform pg_temp.ok('F1 ... it is verified instead', billing.run(pe + interval '26 hours')->'verify' ? ref);
  perform pg_temp.answer(ref, 'pending', pe + interval '26 hours');
  perform pg_temp.eq('F1 Paystack still says pending after 24 h: failed', (select status from billing.payment_attempts where reference = ref), 'failed');
  perform pg_temp.ok('F1 ... with no lease', (select claimed_until is null from billing.payment_attempts where reference = ref));

  pe := pg_temp.member(d, 'f1d', 990020104);
  ref := pg_temp.job(d, pe, 'not_found');
  perform pg_temp.answer(ref, 'pending', pe + interval '2 minutes');
  perform pg_temp.eq('F1 a late pending on a void try: still active', pg_temp.st(d, pe + interval '3 minutes', 'state'), 'active');
end $$;

-- F2 an upgrade bill with a saved-card charge on its way is not replaced; one with only
--    an open card page is
do $$
declare a uuid := pg_temp.acct('f2'); pe timestamptz; inv uuid; inv2 uuid; ref text;
begin
  perform pg_temp.link(a, 'f2', '{990020201,990020202,990020203}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990020201}', pg_temp.t(0), 'AUTH_f2');
  inv := (billing.upgrade(a, 'family', 0, '{990020201,990020202}', pg_temp.t(5))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(5))->>'reference';
  inv2 := (billing.upgrade(a, 'family', 0, '{990020201,990020202,990020203}', pg_temp.t(5))->>'invoice')::uuid;
  perform pg_temp.ok('F2 an open card page: the new upgrade replaces it', inv2 <> inv
    and (select status = 'void' from billing.invoices where id = inv)
    and (select status = 'pending' and replaced_at is not null from billing.payment_attempts where reference = ref));
  perform pg_temp.answer(ref, 'abandoned', pg_temp.t(5));                -- the replaced page verified: it cannot pay
  perform billing.begin_attempt(inv2, 'saved_card', pg_temp.t(5));
  perform pg_temp.fails('F2 second upgrade while a charge may still take money',
    format('select billing.upgrade(%L, ''family'', 0, ''{990020201,990020202}'', %L)', a, pg_temp.t(5)), 'already in progress');
  perform pg_temp.eq('F2 the charged bill stays open', (select status from billing.invoices where id = inv2), 'open');
end $$;

-- F3 a paid try later reversed: recorded against it, access for that period ends
do $$
declare a uuid := pg_temp.acct('f3'); ref text; r jsonb;
begin
  perform pg_temp.member(a, 'f3', 990020301);
  ref := (select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice where i.account = a);
  r := billing.apply_payment(ref, jsonb_build_object('status', 'reversed', 'reference', ref), pg_temp.t(2));
  perform pg_temp.eq('F3 reversal on the current period: plan ends', r->>'action', 'plan_ended');
  perform pg_temp.eq('F3 ended', pg_temp.st(a, pg_temp.t(2), 'state'), 'ended');
  perform pg_temp.ok('F3 recorded against the try', exists (select 1 from billing.refunds rf join billing.payment_attempts pa on pa.id = rf.attempt
    where pa.reference = ref and rf.reason = 'reversed' and rf.status = 'processed' and pa.status = 'reversed'));
  perform pg_temp.eq('F3 a replay changes nothing',
    billing.apply_payment(ref, jsonb_build_object('status', 'reversed', 'reference', ref), pg_temp.t(3))->>'action', 'again');
end $$;

-- F4 a resolved dispute is final; lost on a plan the clock has ended: owed, end date kept
do $$
declare a uuid := pg_temp.acct('f4'); b uuid := pg_temp.acct('f4b'); ref text; r jsonb; pe timestamptz;
begin
  perform pg_temp.member(a, 'f4', 990020401);
  ref := (select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice where i.account = a);
  r := billing.record_dispute(ref, 'charge.dispute.resolve', 'lost', true, 4900, pg_temp.t(2), 'DSP_1');
  perform pg_temp.eq('F4 lost: plan ended', r->>'action', 'plan_ended');
  r := billing.record_dispute(ref, 'charge.dispute.resolve', 'lost', true, 4900, pg_temp.t(3), 'DSP_1');
  perform pg_temp.eq('F4 replay: nothing new', r->>'action', 'again');
  perform pg_temp.ok('F4 nothing owed twice', (select amount_owed_minor = 0 from billing.invoices i join billing.payment_attempts pa on pa.invoice = i.id where pa.reference = ref));
  r := billing.record_dispute(ref, 'charge.dispute.remind', 'awaiting-merchant-feedback', false, null, pg_temp.t(4), 'DSP_1');
  perform pg_temp.ok('F4 a later remind does not reopen it', r->>'action' = 'again'
    and not (select dispute_open from billing.payment_attempts where reference = ref));

  pe := pg_temp.member(b, 'f4b', 990020402);
  perform billing.cancel(b, pg_temp.t(1));
  ref := (select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice where i.account = b);
  r := jsonb_build_object('v', (select version from billing.accounts where id = b));
  r := billing.record_dispute(ref, 'charge.dispute.resolve', 'lost', true, 4900, pe + interval '2 days')
       || jsonb_build_object('v', (r->>'v')::bigint);
  perform pg_temp.ok('F4 owed moves the account version', (select version from billing.accounts where id = b) > (r->>'v')::bigint);
  perform pg_temp.eq('F4 lost after the cancel date: owed', r->>'action', 'owed');
  perform pg_temp.eqt('F4 end date kept', pg_temp.st(b, pe + interval '2 days', 'access_ended_at'), pe);
end $$;

-- F5 a success must name the exact reference
do $$
declare a uuid := pg_temp.acct('f5'); inv uuid; ref text;
begin
  perform pg_temp.link(a, 'f5', '{990020501}', pg_temp.t(0));
  inv := (billing.start_checkout(a, 'home', 'month', 0, '{990020501}', pg_temp.t(0))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(0))->>'reference';
  perform pg_temp.fails('F5 success with no reference refused',
    format('select billing.apply_payment(%L, %L, %L)', ref, pg_temp.tx_ok(ref) - 'reference', pg_temp.t(0)), 'does not match');
  perform pg_temp.eq('F5 nothing applied', pg_temp.st(a, pg_temp.t(0), 'state'), 'none');
end $$;

-- F6 a window that starts after the job's clock charges nothing
do $$
declare a uuid := pg_temp.acct('f6'); pe timestamptz;
begin
  pe := pg_temp.member(a, 'f6', 990020601);
  perform pg_temp.job(a, pe, 'fail');
  update billing.subscriptions set past_due_since = pe + interval '2 days' where account = a and status = 'past_due';
  perform pg_temp.eq('F6 no retry day reached yet: no charge', pg_temp.job(a, pe + interval '1 day'), null);
end $$;

-- F7 paid before day 15, answer after the job ended it: applied; a restart after a plan
--    the clock ended but the job did not: accepted
do $$
declare a uuid := pg_temp.acct('f7'); b uuid := pg_temp.acct('f7b'); pe timestamptz; inv uuid; ref text; r jsonb; tx jsonb;
begin
  pe := pg_temp.member(a, 'f7', 990020701);
  perform pg_temp.job(a, pe, 'fail');
  inv := (billing.pay_now(a, pe + interval '14 days')->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pe + interval '14 days')->>'reference';
  perform billing.run(pe + interval '15 days 1 hour');
  perform pg_temp.eq('F7 the job ended it on day 15', (pg_temp.sub(a)).status, 'ended');
  tx := pg_temp.tx_ok(ref, 'AUTH_f7') || jsonb_build_object('paid_at', pe + interval '14 days 5 minutes');
  r := billing.apply_payment(ref, tx, pe + interval '16 days');
  perform pg_temp.eq('F7 paid before day 15: applied', r->>'action', 'applied');
  perform pg_temp.eq('F7 active again', pg_temp.st(a, pe + interval '16 days', 'state'), 'active');
  perform pg_temp.ok('F7 same plan row, next period', (pg_temp.sub(a)).period_start = pe and (select count(*) = 1 from billing.subscriptions where account = a));

  pe := pg_temp.member(b, 'f7b', 990020702);
  perform billing.cancel(b, pg_temp.t(1));
  inv := (billing.start_checkout(b, 'home', 'month', 0, '{990020702}', pe + interval '1 day')->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pe + interval '1 day')->>'reference';
  r := pg_temp.answer(ref, 'ok', pe + interval '1 day');
  perform pg_temp.eq('F7 restart before the job ended the old plan: applied', r->>'action', 'applied');
  perform pg_temp.ok('F7 old plan ended on its cancel date', exists (select 1 from billing.subscriptions where account = b and status = 'ended' and ended_at = pe));
end $$;

-- F8 an upgrade paid after its quoted period ended: refunded
do $$
declare a uuid := pg_temp.acct('f8'); pe timestamptz; inv uuid; ref text; r jsonb;
begin
  perform pg_temp.link(a, 'f8', '{990020801,990020802}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990020801}', pg_temp.t(0), 'AUTH_f8');
  pe := (pg_temp.sub(a)).period_end;
  inv := (billing.upgrade(a, 'family', 0, '{990020801,990020802}', pe - interval '2 days')->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pe - interval '2 days')->>'reference';
  r := pg_temp.answer(ref, 'ok', pe + interval '1 hour');
  perform pg_temp.eq('F8 settled after the period: refunded', r->>'reason', 'stale');
end $$;

-- F9 a new card while past due pays the bill, not the R1 check
do $$
declare a uuid := pg_temp.acct('f9'); pe timestamptz;
begin
  pe := pg_temp.member(a, 'f9', 990020901);
  perform pg_temp.job(a, pe, 'fail');
  perform pg_temp.eq('F9 new card pays the renewal', billing.start_card_check(a, pe + interval '1 day')->>'kind', 'renewal');
end $$;

-- F11 a hard decline asks for a new card, once per bill
do $$
declare a uuid := pg_temp.acct('f11'); pe timestamptz; r text;
begin
  pe := pg_temp.member(a, 'f11', 990021101);
  r := pg_temp.job(a, pe, 'hard');
  perform pg_temp.ok('F11 update-card email queued for that bill', (select count(*) = 1 from billing.outbox o
    join billing.payment_attempts pa on pa.invoice = o.invoice where pa.reference = r and o.key = 'card_update'));
end $$;

-- F12 the last launch place goes to one checkout; a place is freed when a checkout lapses
do $$
declare a uuid := pg_temp.acct('f12a'); b uuid := pg_temp.acct('f12b'); members int;
begin
  -- other tests' checkouts left open hold places until verified: let them go first
  update billing.payment_attempts set status = 'void' where status in ('created', 'pending', 'unknown')
     and invoice in (select id from billing.invoices where kind = 'purchase' and status = 'open');
  members := (select count(distinct account) from billing.subscriptions where offer = 'launch');
  update billing.offers set max_members = members + 1 where code = 'launch';
  perform pg_temp.link(a, 'f12a', '{990021201}', pg_temp.t(0));
  perform pg_temp.link(b, 'f12b', '{990021202}', pg_temp.t(0));
  perform pg_temp.eq('F12 first checkout: launch price',
    billing.start_checkout(a, 'home', 'month', 0, '{990021201}', pg_temp.t(200))->>'amount_minor', '4900');
  perform pg_temp.eq('F12 second checkout: the place is held',
    billing.start_checkout(b, 'home', 'month', 0, '{990021202}', pg_temp.t(200))->>'amount_minor', '9900');
  perform pg_temp.eq('F12 first checkout lapsed after an hour: place free again',
    billing.start_checkout(b, 'home', 'month', 0, '{990021202}', pg_temp.t(200) + interval '2 hours')->>'amount_minor', '4900');
  update billing.offers set max_members = 100 where code = 'launch';
end $$;

-- F13 refund events out of order: processed stays processed
do $$
declare a uuid := pg_temp.acct('f13'); inv uuid; ref text; rf uuid;
begin
  perform pg_temp.link(a, 'f13', '{990021301}', pg_temp.t(0));
  inv := (billing.start_card_check(a, pg_temp.t(0))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(0))->>'reference';
  rf := (pg_temp.answer(ref, 'ok', pg_temp.t(0))->>'refund')::uuid;
  perform billing.record_refund(rf, null, 'RF_f13', pg_temp.t(0));
  perform billing.record_refund_event(ref, 'processed', 'RF_f13', 100, null, pg_temp.t(1));
  perform billing.record_refund_event(ref, 'pending', 'RF_f13', 100, null, pg_temp.t(2));
  perform pg_temp.eq('F13 late pending after processed', (select status from billing.refunds where id = rf), 'processed');
  -- an event with no refund id is matched on the payment's reference
  update billing.refunds set status = 'pending' where id = rf;
  perform billing.record_refund_event(ref, 'processed', null, 100, null, pg_temp.t(3), 'RFREF_f13');
  perform pg_temp.ok('F13 no id: matched, no second row', (select status = 'processed' from billing.refunds where id = rf)
    and (select count(*) = 1 from billing.refunds where reference = ref));
end $$;

-- F15 a plan the clock ended shows no next plan; a card with no expiry is not "expires first"
do $$
declare a uuid := pg_temp.acct('f15'); pe timestamptz; r jsonb;
begin
  pe := pg_temp.member(a, 'f15', 990021501);
  update billing.payment_methods set exp_month = null, exp_year = null where account = a and active;
  r := billing.account_state(a, pg_temp.t(1));
  perform pg_temp.eq('F15 no expiry: not expiring first', r->>'card_expires_first', 'false');
  perform pg_temp.job(a, pe, 'fail');
  r := billing.account_state(a, pe + interval '16 days');       -- day 15 passed, the job not run
  perform pg_temp.ok('F15 ended by the clock: no next plan or amount', r->>'state' = 'ended' and r->'next_plan' = 'null'::jsonb
    and r->'next_amount_minor' = 'null'::jsonb);
end $$;

-- F18 an open dispute blocks deleting an account that could otherwise go
do $$
declare a uuid := pg_temp.acct('f18'); pe timestamptz; ref text;
begin
  pe := pg_temp.member(a, 'f18', 990021801);
  perform billing.cancel(a, pg_temp.t(1));
  ref := (select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice where i.account = a);
  perform pg_temp.eq('F18 ended, no dispute: may delete', pg_temp.st(a, pe + interval '1 day', 'may_delete'), 'true');
  perform billing.record_dispute(ref, 'charge.dispute.create', 'awaiting-merchant-feedback', false, null, pe + interval '2 days');
  perform pg_temp.eq('F18 dispute open: may not delete', pg_temp.st(a, pe + interval '2 days', 'may_delete'), 'false');
  perform billing.record_dispute(ref, 'charge.dispute.resolve', 'won', false, null, pe + interval '3 days');
  perform pg_temp.eq('F18 dispute won: may delete again', pg_temp.st(a, pe + interval '3 days', 'may_delete'), 'true');
end $$;

-- ===========================================================================
-- Phase 3: reading, deleting and history fetches (0246). No network: the poller's
-- and recover's writes are called directly with made-up rows; the clock moves.
-- ===========================================================================
-- the stored inverter-cloud login behind a billing login (same id, as copy_from_old keeps)
create function pg_temp.stored(p_login uuid) returns uuid language sql as $$
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind)
  select l.id, a.user_id, 'stored-' || l.id, 'active', 'login'
    from billing.logins l join billing.accounts a on a.id = l.account where l.id = p_login
  returning id
$$;
create function pg_temp.share_login() returns uuid language plpgsql as $$
declare s uuid; u uuid := gen_random_uuid();
begin
  select id into s from private.sunsynk_accounts where kind = 'share';
  if s is null then
    insert into auth.users (id, email, created_at) values (u, 'share@state.test', now());
    insert into private.sunsynk_accounts (user_id, sunsynk_username, status, kind) values (u, 'share', 'active', 'share')
    returning id into s;
  end if;
  update private.sunsynk_accounts set status = 'active' where id = s and status <> 'active';
  return s;
end $$;
create function pg_temp.lane_of(p_plant bigint, p_at timestamptz) returns text language sql as $$
  select coalesce((select account_id::text from public.poll_jobs_v2(0, 1, null, p_at) where plant_id = p_plant), '<not read>')
$$;
create function pg_temp.ver(p_plant bigint) returns bigint language sql as $$
  select version from billing.plants where id = p_plant
$$;
-- stored history for a plant, as a guarded write would leave it (the clock here is not now())
create function pg_temp.agg(p_plant bigint, p_at timestamptz, p_guarded boolean default true) returns void language sql as $$
  select set_config('billing.guarded', case when p_guarded then 'on' else 'off' end, true);
  insert into public.agg_minute (plant_id, ts, pv_w, source)
  values (p_plant, extract(epoch from date_trunc('minute', p_at))::bigint, 100, 'poller')
  on conflict do nothing;
  select set_config('billing.guarded', 'off', true);
$$;
create function pg_temp.has_agg(p_plant bigint) returns boolean language sql as $$
  select exists (select 1 from public.agg_minute where plant_id = p_plant)
$$;
create function pg_temp.fetch_row(p_acc uuid, p_plant bigint) returns billing.history_fetches language sql as $$
  select * from billing.history_fetches where account = p_acc and plant = p_plant order by id desc limit 1
$$;
create function pg_temp.alert(p_kind text, p_ref text, p_at timestamptz) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(billing.alerts(p_at)) a where a->>'kind' = p_kind and a->>'ref' = p_ref)
$$;

do $$
begin
  perform billing.switch_on(pg_temp.t(0));
  -- earlier blocks queued fetches with no stored login behind them: start clean
  update billing.history_fetches set status = 'dropped', drop_reason = 'replaced', finished_at = pg_temp.t(0)
   where status in ('queued', 'running');
  perform pg_temp.ok('R0 switched on', billing.is_live());
end $$;

-- ---------------------------------------------------------------------------
-- R1 read_now through two logins and a share claim; a broken login
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('r1'); l1 uuid; l2 uuid; sh uuid := pg_temp.share_login(); n int;
begin
  l1 := pg_temp.link(a, 'r1a', '{990030101,990030102}', pg_temp.t(0));
  perform pg_temp.stored(l1);
  perform pg_temp.choose(a, '{990030101,990030102}', pg_temp.t(0));
  perform pg_temp.pay(a, 'family', 'month', pg_temp.t(0.5));
  l2 := pg_temp.link(a, 'r1b', '{990030102}', pg_temp.t(0.6));
  perform pg_temp.stored(l2);
  insert into billing.plants (id, brand, external_id) values (990030103, 'sunsynk', '990030103');
  insert into billing.plant_claims (plant, account, claimed_at) values (990030103, a, pg_temp.t(0.6));
  perform pg_temp.choose(a, '{990030101,990030102,990030103}', pg_temp.t(0.7));

  select count(*) into n from public.poll_jobs_v2(0, 1, null, pg_temp.t(1)) where plant_id = 990030102;
  perform pg_temp.eq('R1 plant on two logins read once', n::text, '1');
  perform pg_temp.eq('R1 through the earlier login', pg_temp.lane_of(990030102, pg_temp.t(1)), l1::text);
  perform pg_temp.eq('R1 share claim read through the share login', pg_temp.lane_of(990030103, pg_temp.t(1)), sh::text);
  perform pg_temp.ok('R1 job carries the plant version', (select plant_version = pg_temp.ver(990030101)
    from public.poll_jobs_v2(0, 1, null, pg_temp.t(1)) where plant_id = 990030101));
  select count(*) into n from public.poll_jobs_v2(0, 2, null, pg_temp.t(1)) where plant_id = 990030101;
  select n + count(*) into n from public.poll_jobs_v2(1, 2, null, pg_temp.t(1)) where plant_id = 990030101;
  perform pg_temp.eq('R1 in exactly one shard', n::text, '1');
  perform pg_temp.eq('R1 one account only', (select count(*)::text from public.poll_jobs_v2(0, 1, l2, pg_temp.t(1))), '0');

  -- l1 breaks: the shared plant moves to l2, the other is not read, history kept
  perform pg_temp.agg(990030101, pg_temp.t(1));
  n := pg_temp.ver(990030101);
  update private.sunsynk_accounts set status = 'needs_relink' where id = l1;
  perform pg_temp.eq('R1 broken login copied to billing', (select status from billing.logins where id = l1), 'needs_reconnect');
  perform pg_temp.ok('R1 its plants'' versions moved', pg_temp.ver(990030101) = n + 1);
  perform pg_temp.eq('R1 shared plant now through the other login', pg_temp.lane_of(990030102, pg_temp.t(1)), l2::text);
  perform pg_temp.eq('R1 broken login: not read', pg_temp.lane_of(990030101, pg_temp.t(1)), '<not read>');
  perform pg_temp.eq('R1 broken login: protected', pg_temp.ps(990030101, pg_temp.t(1), 'protected'), 'true');
  perform billing.delete_due(pg_temp.t(1));
  perform pg_temp.ok('R1 broken login: history kept by the delete job', pg_temp.has_agg(990030101));
  perform pg_temp.ok('R1 status change logged', exists (select 1 from billing.account_events where account = a and kind = 'login_status'));
  update private.sunsynk_accounts set status = 'active' where id = l1;
  perform pg_temp.eq('R1 fixed: read again', pg_temp.lane_of(990030101, pg_temp.t(1)), l1::text);
  update private.sunsynk_accounts set status = 'disabled' where id = l1;
  perform pg_temp.eq('R1 disabled is not a broken login', (select status from billing.logins where id = l1), 'ok');
  update private.sunsynk_accounts set status = 'active' where id = l1;
end $$;

-- ---------------------------------------------------------------------------
-- R2 a switch during a fetch writes nothing; the switched-out request is dropped
-- ---------------------------------------------------------------------------
do $$
declare b uuid := pg_temp.acct('r2'); l uuid; v bigint; r jsonb;
begin
  l := pg_temp.link(b, 'r2', '{990030201,990030202}', pg_temp.t(0));
  perform pg_temp.stored(l);
  perform pg_temp.choose(b, '{990030201}', pg_temp.t(0));
  v := pg_temp.ver(990030201);
  perform pg_temp.eq('R2 first plant queued for history', (pg_temp.fetch_row(b, 990030201)).status, 'queued');
  perform pg_temp.choose(b, '{990030202}', pg_temp.t(0.5));      -- switched while the minute was read
  r := public.poll_commit_v2(jsonb_build_object('990030201', v), l, extract(epoch from pg_temp.t(0.5))::bigint,
         '[]', '[]', jsonb_build_array(jsonb_build_object('plant_id', 990030201, 'pv_w', 5)), '[]', '[]', null, null, pg_temp.t(0.5));
  perform pg_temp.eq('R2 poll write refused', r->>'refused', '[990030201]');
  perform pg_temp.ok('R2 nothing written', not pg_temp.has_agg(990030201));
  perform pg_temp.fails('R2 recover write refused',
    format('select public.q_insert_recovered_v2(990030201, %s, %L, %L, %L)', v,
           jsonb_build_array(jsonb_build_object('ts', extract(epoch from pg_temp.t(-3))::bigint, 'pv_w', 1)), 'invhistory', pg_temp.t(0.5)),
    'is not read now');
  perform pg_temp.fails('R2 a write with no version is refused',
    format('select public.q_insert_inverter_history_v2(990030202, null, %L, %L, %L)', 'SN1', '[]', pg_temp.t(0.5)), 'is not read now');
  perform pg_temp.eq('R2 switched-out request dropped', (pg_temp.fetch_row(b, 990030201)).drop_reason, 'switched_out');
  perform pg_temp.eq('R2 new plant queued', (pg_temp.fetch_row(b, 990030202)).status, 'queued');
  r := public.poll_commit_v2(jsonb_build_object('990030202', pg_temp.ver(990030202)), l, extract(epoch from pg_temp.t(0.6))::bigint,
         '[]', '[]', jsonb_build_array(jsonb_build_object('plant_id', 990030202, 'pv_w', 5)), '[]', '[]', 'tok', 1, pg_temp.t(0.6));
  perform pg_temp.ok('R2 the plant read now is written', r->'refused' = '[]'::jsonb and pg_temp.has_agg(990030202));
  perform pg_temp.eq('R2 token saved', (select access_token from private.sunsynk_accounts where id = l), 'tok');
end $$;

-- ---------------------------------------------------------------------------
-- R3 the delete job: waits for a pending payment, then deletes; purge then new readings;
--    a restart fetches the kept plant again; the win-back event
-- ---------------------------------------------------------------------------
do $$
declare c uuid := pg_temp.acct('r3'); l uuid; inv uuid; ref text; r jsonb; v bigint; uid uuid;
begin
  l := pg_temp.link(c, 'r3', '{990030301}', pg_temp.t(0));
  perform pg_temp.stored(l);
  perform pg_temp.choose(c, '{990030301}', pg_temp.t(0));
  perform pg_temp.agg(990030301, pg_temp.t(1));
  perform pg_temp.eqt('R3 week over unpaid: deleted 30 days after', pg_temp.ps(990030301, pg_temp.t(8), 'delete_at'), pg_temp.t(37));
  r := billing.delete_due(pg_temp.t(36));
  perform pg_temp.ok('R3 not before its date', pg_temp.has_agg(990030301));

  inv := (billing.start_checkout(c, 'home', 'month', 0, '{990030301}', pg_temp.t(37.5))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(37.5))->>'reference';
  r := billing.delete_due(pg_temp.t(38));
  perform pg_temp.eq('R3 held while a payment is pending', r->>'held', '[990030301]');
  perform pg_temp.ok('R3 history still there', pg_temp.has_agg(990030301));
  perform pg_temp.ok('R3 held plant is not an alert', not pg_temp.alert('history_unprotected', '990030301', pg_temp.t(38)));
  perform pg_temp.ok('R3 try pending over an hour: alert', pg_temp.alert('attempt_pending', ref, pg_temp.t(38)));
  perform pg_temp.ok('R3 history past its date, no hold: alert', pg_temp.alert('history_unprotected', '990030301', pg_temp.t(39)));
  v := pg_temp.ver(990030301);
  r := billing.delete_due(pg_temp.t(39));
  perform pg_temp.eq('R3 deleted once the hold is over 24 hours', r->>'deleted', '[990030301]');
  perform pg_temp.ok('R3 readings gone', not pg_temp.has_agg(990030301));
  perform pg_temp.eqt('R3 purge recorded', (select history_purged_at::text from billing.plants where id = 990030301), pg_temp.t(39));
  perform pg_temp.ok('R3 version moved', pg_temp.ver(990030301) = v + 1);
  perform pg_temp.eq('R3 purged: no kept-until', pg_temp.ps(990030301, pg_temp.t(39), 'delete_at'), null);
  perform pg_temp.ok('R3 no alert after the delete', not pg_temp.alert('history_unprotected', '990030301', pg_temp.t(39)));
  r := billing.delete_due(pg_temp.t(40));
  perform pg_temp.ok('R3 a purged plant is skipped', not (r->'deleted') @> '[990030301]');
  perform pg_temp.ok('R3 heartbeat written', (select last_run_at from billing.job_heartbeats where job = 'delete') = pg_temp.t(40));

  -- the late payment lands: the plan restarts, the kept plant is fetched again
  uid := (select user_id from billing.accounts where id = c);
  insert into public.email_queue (user_id, kind, key, due_at) values (uid, 'winback', 'winback:state-test-late:' || uid, pg_temp.t(37));
  perform pg_temp.ok('O0 after the switch an old billing email is not queued',
    not exists (select 1 from public.email_queue where key = 'winback:state-test-late:' || uid));
  -- one sent before the switch
  set local session_replication_role = replica;
  insert into public.email_queue (user_id, kind, key, due_at) values (uid, 'winback', 'winback:state-test:' || uid, pg_temp.t(37));
  set local session_replication_role = origin;
  update public.email_queue set status = 'sent', sent_at = pg_temp.t(37) where key = 'winback:state-test:' || uid;
  r := pg_temp.answer(ref, 'ok', pg_temp.t(40));
  perform pg_temp.eq('R3 payment applied', r->>'action', 'applied');
  perform pg_temp.ok('R3 restart: history asked for again', (select status = 'queued' and requested_at = pg_temp.t(40)
    from billing.history_fetches where account = c and plant = 990030301 order by id desc limit 1));
  perform pg_temp.ok('R3 win-back return found', (billing.winback_return(ref)->>'user')::uuid = uid
    and (billing.winback_return(ref)->>'days')::int = 3);
  r := public.billing_jobs('winback', jsonb_build_object('reference', ref));
  perform pg_temp.ok('R3 win-back through the door', r ? 'email_id');
  perform pg_temp.ok('R3 the old public.winback_return reads the new tables', (select w.user_id = uid and w.days = 3
    from public.winback_return(ref) w));

  perform public.q_insert_recovered_v2(990030301, pg_temp.ver(990030301),
    jsonb_build_array(jsonb_build_object('ts', extract(epoch from date_trunc('minute', pg_temp.t(39.5)))::bigint, 'pv_w', 7)),
    'invhistory', pg_temp.t(40));
  perform pg_temp.ok('R3 new readings written', pg_temp.has_agg(990030301));
  perform pg_temp.eq('R3 the restart cleared the purge (phase 3 fix 20: not the readings)', (select history_purged_at::text from billing.plants where id = 990030301), null);
  perform pg_temp.eq('R3 a whole past day is missing for the history queue',
    (select count(*)::text from public.q_missing_minutes_day(990030301, (now() at time zone 'Africa/Johannesburg')::date - 3)), '1440');
end $$;

-- ---------------------------------------------------------------------------
-- R4 fetch speed: fetches 1-3 normal, then twice as long each time, capped at 24 h;
--    a fetch drops out of the count after 7 days; slowed by the wait between days
-- ---------------------------------------------------------------------------
do $$
declare d uuid := pg_temp.acct('r4'); l uuid; i int; got text := ''; f billing.history_fetches; w jsonb; s jsonb;
begin
  l := pg_temp.link(d, 'r4', '{990030401,990030402,990030403,990030404,990030405,990030406,990030407,990030408}', pg_temp.t(0));
  perform pg_temp.stored(l);
  perform pg_temp.pay(d, 'home', 'month', pg_temp.t(0));
  for i in 1..7 loop
    perform pg_temp.choose(d, array[990030400 + i]::bigint[], pg_temp.t(i * 0.1));
    got := got || (pg_temp.fetch_row(d, 990030400 + i)).target_s || ' ';
  end loop;
  -- the first choice after the login was linked is not a switch: not counted
  perform pg_temp.eq('R4 targets for choices 1-7', got, '0 0 0 0 1200 2400 4800 ');
  perform pg_temp.eq('R4 first choice after the link not counted', (select (after->>'counted') from billing.account_events
    where account = d and kind = 'history_fetch' order by id limit 1), 'false');
  perform pg_temp.eq('R4 fetch number logged', (select max((after->>'fetch_no')::int)::text from billing.account_events
    where account = d and kind = 'history_fetch'), '6');
  perform pg_temp.ok('R4 seven switches in a week: alert', pg_temp.alert('many_switches', d::text, pg_temp.t(1)));
  perform pg_temp.ok('R4 not after the week', not pg_temp.alert('many_switches', d::text, pg_temp.t(8)));
  -- 7 days after the 4th (t 0.4): fetches at 0.5, 0.6, 0.7 still count, so this is the 4th
  perform pg_temp.choose(d, '{990030408}', pg_temp.t(7.4));
  perform pg_temp.eq('R4 older fetches dropped out of the count', (pg_temp.fetch_row(d, 990030408)).fetch_no::text, '4');
  perform pg_temp.eq('R4 so it is 20 minutes again', (pg_temp.fetch_row(d, 990030408)).target_s::text, '1200');
  -- the 1200 s fetch starts at once and spreads over its 60 days: 20 s a day
  w := billing.history_take(pg_temp.t(7.4));
  f := pg_temp.fetch_row(d, 990030408);
  perform pg_temp.ok('R4 started at once', f.status = 'running' and f.started_at = pg_temp.t(7.4) and f.days_total = 60);
  perform pg_temp.ok('R4 handed out with its login and version', exists (select 1 from jsonb_array_elements(w) x
    where (x->>'id')::bigint = f.id and x->'login'->>'id' = l::text and (x->>'version')::bigint = pg_temp.ver(990030408)));
  s := billing.history_step(f.id, f.day_next, false, false, pg_temp.t(7.4) + interval '5 seconds', f.claim);
  -- 60 starts on 59 gaps: 1200 s / 59 after the start (phase 3 fix 17)
  perform pg_temp.eqt('R4 next day waits a 59th of the target', s->>'next_step_at', pg_temp.t(7.4) + make_interval(secs => 1200.0 / 59));
  -- 20 s away: the claim is let go and history_take hands the day out when it is due, so two
  -- runs never walk it (phase 4 fix 18); go only while the next day is due within 5 s
  perform pg_temp.ok('R4 a slowed day: no go, the claim let go', not (s->>'go')::boolean and (s->>'day')::date = f.day_next - 1
    and (select claim is null and claimed_until is null from billing.history_fetches where id = f.id));
  -- the earliest finish: the last day starts no earlier than the target after the start
  update billing.history_fetches set day_next = day_floor + 1, claimed_until = pg_temp.t(7.5), claim = gen_random_uuid()
   where id = f.id returning * into f;
  s := billing.history_step(f.id, f.day_next, false, false, pg_temp.t(7.4) + interval '30 seconds', f.claim);
  perform pg_temp.ok('R4 the last day starts at the target or later (fix 17)',
    (s->>'next_step_at')::timestamptz >= f.started_at + make_interval(secs => f.target_s));
  -- the cap: eleven fetches in a day
  for i in 1..11 loop
    perform pg_temp.choose(d, array[990030401 + (i % 2)]::bigint[], pg_temp.t(20 + i * 0.01));
  end loop;
  perform pg_temp.eq('R4 capped at 24 h', (select target_s::text from billing.history_fetches where account = d
    order by id desc limit 1), '86400');
end $$;

-- ---------------------------------------------------------------------------
-- R5 the queue: one fetch per login at a time; turns per account on the share login;
--    429 backs the login off; a finished walk is done
-- ---------------------------------------------------------------------------
do $$
declare e1 uuid := pg_temp.acct('r5a'); e2 uuid := pg_temp.acct('r5b'); sh uuid := pg_temp.share_login();
        w jsonb; f billing.history_fetches; s jsonb; n int;
begin
  -- R1's claim fetch holds the share login since R4's take: finish it
  update billing.history_fetches set status = 'done', finished_at = pg_temp.t(0) where lane = sh and status = 'running';
  insert into billing.plants (id, brand, external_id) values (990030501, 'sunsynk', '990030501'),
    (990030502, 'sunsynk', '990030502'), (990030503, 'sunsynk', '990030503');
  insert into billing.plant_claims (plant, account, claimed_at) values (990030501, e1, pg_temp.t(0)),
    (990030502, e1, pg_temp.t(0)), (990030503, e2, pg_temp.t(0));
  perform pg_temp.choose(e1, '{990030501,990030502}', pg_temp.t(0));
  perform pg_temp.choose(e2, '{990030503}', pg_temp.t(0.001));
  w := billing.history_take(pg_temp.t(0.01));
  select count(*) into n from billing.history_fetches where lane = sh and status = 'running';
  perform pg_temp.eq('R5 one fetch at a time on the share login', n::text, '1');
  perform pg_temp.eq('R5 first asked, first started', (pg_temp.fetch_row(e1, 990030501)).status, 'running');
  update billing.history_fetches set status = 'done', finished_at = pg_temp.t(0.02) where account = e1 and plant = 990030501;
  w := billing.history_take(pg_temp.t(0.02));
  perform pg_temp.eq('R5 the other account takes its turn', (pg_temp.fetch_row(e2, 990030503)).status, 'running');
  perform pg_temp.eq('R5 the first account waits', (pg_temp.fetch_row(e1, 990030502)).status, 'queued');

  f := pg_temp.fetch_row(e2, 990030503);
  s := billing.history_step(f.id, f.day_next, false, true, pg_temp.t(0.03), f.claim);
  perform pg_temp.eq('R5 429: backed off a minute', s->>'backoff_s', '60');
  w := billing.history_take(pg_temp.t(0.03) + interval '30 seconds');
  perform pg_temp.ok('R5 nothing handed out on a backed-off login', not exists (select 1 from jsonb_array_elements(w) x
    where (x->>'id')::bigint = f.id));
  w := billing.history_take(pg_temp.t(0.03) + interval '61 seconds');
  f := pg_temp.fetch_row(e2, 990030503);
  s := billing.history_step(f.id, f.day_next, false, true, pg_temp.t(0.03) + interval '62 seconds', f.claim);
  perform pg_temp.eq('R5 429 again: twice as long', s->>'backoff_s', '120');
  -- the walk ends at its floor
  update billing.history_fetches set day_next = day_floor, claimed_until = null, claim = gen_random_uuid() where id = f.id
  returning * into f;
  s := billing.history_step(f.id, f.day_floor, false, false, pg_temp.t(0.1), f.claim);
  perform pg_temp.eq('R5 last day walked: done', (pg_temp.fetch_row(e2, 990030503)).status, 'done');
  perform pg_temp.ok('R5 a good answer clears the back-off', (select backoff_s = 0 from billing.history_lanes where lane = sh));
  w := billing.history_take(pg_temp.t(0.11));
  perform pg_temp.eq('R5 then the first account again', (pg_temp.fetch_row(e1, 990030502)).status, 'running');
  -- switched out while running: dropped at the next step
  perform pg_temp.choose(e1, '{990030501}', pg_temp.t(0.12));
  perform pg_temp.eq('R5 switched out: dropped', (pg_temp.fetch_row(e1, 990030502)).drop_reason, 'switched_out');
  -- the share login breaks while a fetch runs: it waits, it is not dropped
  perform pg_temp.choose(e1, '{990030501,990030502}', pg_temp.t(0.125));
  update private.sunsynk_accounts set status = 'needs_relink' where id = sh;
  w := billing.history_take(pg_temp.t(0.13));
  f := pg_temp.fetch_row(e1, 990030502);
  perform pg_temp.eq('R5 share login down: the new request waits', f.status, 'queued');
  perform pg_temp.ok('R5 nothing handed out without a working login', not exists (select 1 from jsonb_array_elements(w) x
    where (x->>'plant')::bigint = 990030502));
  update private.sunsynk_accounts set status = 'active' where id = sh;
end $$;

-- ---------------------------------------------------------------------------
-- R6 the poller's plant list; the alert list; heartbeats; the door's rights
-- ---------------------------------------------------------------------------
do $$
declare g uuid := pg_temp.acct('r6'); l uuid; r jsonb; v bigint;
begin
  l := pg_temp.link(g, 'r6', '{990030601,990030602}', pg_temp.t(0));
  perform pg_temp.choose(g, '{990030601,990030602}', pg_temp.t(0));
  r := billing.login_seen(l, '[{"id":990030601},{"id":990030603,"name":"New"}]', pg_temp.t(0.5));
  perform pg_temp.eq('R6 new plant on the login added', r->>'new', '[990030603]');
  perform pg_temp.eq('R6 missing once: not gone yet', r->>'gone', '[]');
  v := pg_temp.ver(990030602);
  r := billing.login_seen(l, '[{"id":990030601},{"id":990030603}]', pg_temp.t(0.5) + interval '1 hour');
  perform pg_temp.eq('R6 missing twice an hour apart: gone', r->>'gone', '[990030602]');
  perform pg_temp.ok('R6 gone plant''s version moved', pg_temp.ver(990030602) = v + 1);
  perform pg_temp.eq('R6 gone plant not read', pg_temp.pp(g, pg_temp.t(1), 990030602, 'read_now'), 'false');
  perform pg_temp.eq('R6 new plant waits to be chosen', pg_temp.pp(g, pg_temp.t(1), 990030603, 'chosen'), 'false');
  perform pg_temp.eq('R6 unknown login: nothing', billing.login_seen(gen_random_uuid(), '[]', pg_temp.t(1))::text, null);

  insert into billing.refunds (reference, reason, status, tries, last_error, created_at, updated_at)
  values ('R6-REF', 'stale', 'failed', 3, 'boom', pg_temp.t(1), pg_temp.t(1));
  insert into public.email_queue (to_email, kind, key, due_at) values ('late@state.test', 'test', 'r6-late', pg_temp.t(0));
  perform pg_temp.ok('R6 failed refund: alert', pg_temp.alert('refund_failed', 'R6-REF', pg_temp.t(2)));
  perform pg_temp.ok('R6 email waiting over an hour: alert', pg_temp.alert('outbox_backlog', 'email_queue', pg_temp.t(2)));
  perform pg_temp.ok('R6 billing run never seen: quiet after 26 h', pg_temp.alert('job_quiet', 'billing-run', pg_temp.t(2)));
  perform public.billing_jobs('heartbeat', jsonb_build_object('job', 'billing-run', 'result', '{}'::jsonb));
  perform pg_temp.ok('R6 heartbeat through the door', exists (select 1 from billing.job_heartbeats where job = 'billing-run'));
  perform pg_temp.ok('R6 history job quiet 10 min after its last run', pg_temp.alert('job_quiet', 'history', pg_temp.t(1)));
  perform pg_temp.ok('R6 alerts through the door', jsonb_typeof(public.billing_jobs('alerts')) = 'array');
  perform pg_temp.fails('R6 unknown command refused', 'select public.billing_jobs(''alertz'')', 'unknown billing_jobs command');
  -- a write outside the guarded functions lands only on a plant read now
  perform pg_temp.agg(990030699, now(), false);
  perform pg_temp.ok('R6 unguarded write to a plant nobody reads dropped', not pg_temp.has_agg(990030699));
  perform pg_temp.ok('R6 not callable by signed-in users',
    not has_function_privilege('authenticated', 'public.billing_jobs(text, jsonb)', 'execute')
    and not has_function_privilege('authenticated', 'public.poll_jobs_v2(int, int, uuid, timestamptz)', 'execute')
    and not has_function_privilege('anon', 'public.poll_commit_v2(jsonb, uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb, text, bigint, timestamptz)', 'execute')
    and not has_function_privilege('authenticated', 'billing.delete_due(timestamptz)', 'execute')
    and has_function_privilege('service_role', 'public.billing_jobs(text, jsonb)', 'execute'));
end $$;

-- ---------------------------------------------------------------------------
-- RQ phase 3 review fixes (history queue, deleting). Fix 17 is in R4.
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('rq14'); b uuid := pg_temp.acct('rq15'); c1 uuid := pg_temp.acct('rq16a');
        c2 uuid := pg_temp.acct('rq16b'); d uuid := pg_temp.acct('rq21'); e uuid := pg_temp.acct('rq22');
        g uuid := pg_temp.acct('rq23'); h uuid := pg_temp.acct('rq24');
        sh uuid := pg_temp.share_login(); l uuid; w jsonb; f billing.history_fetches; s jsonb; old uuid; n int;
begin
  -- 14: only the run holding the claim moves the fetch; a run whose claim ran out is told so
  l := pg_temp.link(a, 'rq14', '{990061401}', pg_temp.t(30)); perform pg_temp.stored(l);
  perform pg_temp.pay(a, 'home', 'month', pg_temp.t(30));
  perform pg_temp.choose(a, '{990061401}', pg_temp.t(30));
  w := billing.history_take(pg_temp.t(30.01));
  f := pg_temp.fetch_row(a, 990061401);
  perform pg_temp.ok('RQ14 handed out with its claim', exists (select 1 from jsonb_array_elements(w) x
    where (x->>'id')::bigint = f.id and (x->>'claim')::uuid = f.claim));
  perform pg_temp.eq('RQ14 a step with another claim is refused',
    billing.history_step(f.id, f.day_next, false, false, pg_temp.t(30.01), gen_random_uuid())->>'status', 'not_yours');
  perform pg_temp.ok('RQ14 the holder renews its claim', billing.history_renew(f.id, f.claim, pg_temp.t(30.01) + interval '60 seconds'));
  old := f.claim;
  w := billing.history_take(pg_temp.t(30.01) + interval '200 seconds');   -- the claim ran out: handed out again
  f := pg_temp.fetch_row(a, 990061401);
  perform pg_temp.ok('RQ14 a new claim after it ran out', f.claim is not null and f.claim <> old);
  perform pg_temp.eq('RQ14 the old run cannot release it',
    billing.history_step(f.id, null, false, false, pg_temp.t(30.01) + interval '201 seconds', old)->>'status', 'not_yours');
  perform pg_temp.ok('RQ14 ... nor renew it', billing.history_renew(f.id, old, pg_temp.t(30.01) + interval '202 seconds') is null);

  -- 15: the share login breaks while a claimed plant's fetch runs: back to the queue, days kept
  update billing.history_fetches set status = 'done', finished_at = pg_temp.t(31) where lane = sh and status = 'running';
  insert into billing.plants (id, brand, external_id) values (990061501, 'sunsynk', '990061501');
  insert into billing.plant_claims (plant, account, claimed_at) values (990061501, b, pg_temp.t(31));
  perform pg_temp.pay(b, 'home', 'month', pg_temp.t(31));
  perform pg_temp.choose(b, '{990061501}', pg_temp.t(31));
  w := billing.history_take(pg_temp.t(31.01));
  f := pg_temp.fetch_row(b, 990061501);
  perform pg_temp.eq('RQ15 running on the share login', f.status || ':' || (f.lane = sh)::text, 'running:true');
  update billing.history_fetches set day_next = day_next - 5 where id = f.id;
  update private.sunsynk_accounts set status = 'needs_relink' where id = sh;
  w := billing.history_take(pg_temp.t(31.02));
  perform pg_temp.eq('RQ15 login broke mid-fetch: back to the queue', (pg_temp.fetch_row(b, 990061501)).status, 'queued');
  perform pg_temp.ok('RQ15 ... its days kept', (pg_temp.fetch_row(b, 990061501)).day_next = f.day_next - 5);
  update private.sunsynk_accounts set status = 'active' where id = sh;
  w := billing.history_take(pg_temp.t(31.03));
  perform pg_temp.ok('RQ15 login back: carries on from where it was', (pg_temp.fetch_row(b, 990061501)).status = 'running'
    and (pg_temp.fetch_row(b, 990061501)).day_next = f.day_next - 5);
  update billing.history_fetches set status = 'done', finished_at = pg_temp.t(31.04) where account = b and status = 'running';

  -- 16: a slowed fetch waiting between days does not hold the shared login
  insert into billing.plants (id, brand, external_id) values (990061601, 'sunsynk', '990061601'), (990061602, 'sunsynk', '990061602');
  insert into billing.plant_claims (plant, account, claimed_at) values (990061601, c1, pg_temp.t(32)), (990061602, c2, pg_temp.t(32));
  perform pg_temp.pay(c1, 'home', 'month', pg_temp.t(32));
  perform pg_temp.pay(c2, 'home', 'month', pg_temp.t(32));
  perform pg_temp.choose(c1, '{990061601}', pg_temp.t(32));
  w := billing.history_take(pg_temp.t(32.01));
  f := pg_temp.fetch_row(c1, 990061601);
  update billing.history_fetches set target_s = 86400 where id = f.id;       -- A's 10th switch: a day long
  s := billing.history_step(f.id, f.day_next, false, false, pg_temp.t(32.01) + interval '10 seconds', f.claim);
  perform pg_temp.ok('RQ16 the slowed fetch waits for its next day', (s->>'next_step_at')::timestamptz > pg_temp.t(32.02));
  perform pg_temp.choose(c2, '{990061602}', pg_temp.t(32.02));
  w := billing.history_take(pg_temp.t(32.02) + interval '1 second');
  perform pg_temp.ok('RQ16 another account''s first fetch starts on the same login at once',
    exists (select 1 from jsonb_array_elements(w) x where (x->>'plant')::bigint = 990061602));

  -- 18: the plants the queue is fetching, for the old recovery schedule to leave alone
  perform pg_temp.ok('RQ18 fetching lists a queued or running plant', public.billing_jobs('fetching') @> '[990061602]');

  -- 20: readings never clear a delete; only a seat opening does
  perform pg_temp.ok('RQ20 no write path touches the plant row', to_regprocedure('billing.readings_arrived(bigint[])') is null);

  -- 21: the full delete clears five-minute history too
  l := pg_temp.link(d, 'rq21', '{990062101}', pg_temp.t(33));
  insert into public.readings_5m (plant_id, sn, ts) values (990062101, 'SN_rq21', extract(epoch from pg_temp.t(33))::bigint);
  perform billing.delete_due(pg_temp.t(33.1));
  perform pg_temp.ok('RQ21 a plant with only 5-minute rows: deleted', not exists (select 1 from public.readings_5m where plant_id = 990062101));
  perform pg_temp.ok('RQ21 ... and marked', (select history_purged_at is not null from billing.plants where id = 990062101));

  -- 22: a seat chosen after the job started keeps the plant
  l := pg_temp.link(e, 'rq22', '{990062201}', pg_temp.t(34)); perform pg_temp.stored(l);
  perform pg_temp.pay(e, 'home', 'month', pg_temp.t(34));
  perform pg_temp.agg(990062201, pg_temp.t(34));
  insert into billing.seats (account, plant, chosen_at) values (e, 990062201, pg_temp.t(34.5));   -- chosen after the job's start
  perform billing.delete_due(pg_temp.t(34.2));
  perform pg_temp.ok('RQ22 chosen after the job started: kept', pg_temp.has_agg(990062201));

  -- 23: a switch deletes at once, so switching straight back finds it gone
  l := pg_temp.link(g, 'rq23', '{990062301,990062302}', pg_temp.t(35)); perform pg_temp.stored(l);
  perform pg_temp.pay(g, 'home', 'month', pg_temp.t(35));
  perform pg_temp.choose(g, '{990062301}', pg_temp.t(35));
  perform pg_temp.agg(990062301, pg_temp.t(35));
  perform pg_temp.choose(g, '{990062302}', pg_temp.t(35.1));
  perform pg_temp.ok('RQ23 switched out: deleted in the same step', not pg_temp.has_agg(990062301));
  perform pg_temp.choose(g, '{990062301}', pg_temp.t(35.2));
  perform pg_temp.ok('RQ23 switched straight back: still gone', not pg_temp.has_agg(990062301)
    and (select history_purged_at is null from billing.plants where id = 990062301));

  -- 24: history with no open seat for over an hour: alert
  l := pg_temp.link(h, 'rq24', '{990062401}', pg_temp.t(36));
  perform pg_temp.pay(h, 'home', 'month', pg_temp.t(36));
  perform pg_temp.choose(h, '{990062401}', pg_temp.t(36));
  perform pg_temp.agg(990062401, pg_temp.t(36));
  perform billing.remove_login(h, l, pg_temp.t(36.1));
  -- remove_login deletes it now (final fix 7); here the delete is undone, as if it were missed
  update billing.plants set history_purged_at = null where id = 990062401;
  perform pg_temp.agg(990062401, pg_temp.t(36.1));
  perform pg_temp.ok('RQ24 not within the hour', not pg_temp.alert('history_unprotected', '990062401', pg_temp.t(36.1) + interval '30 minutes'));
  perform pg_temp.ok('RQ24 history with no seat for over an hour: alert',
    pg_temp.alert('history_unprotected', '990062401', pg_temp.t(36.1) + interval '2 hours'));
end $$;

-- ---------------------------------------------------------------------------
-- SW phase 3 review fixes (switch-over)
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.fails('SW27 switch_on refuses an empty copy', 'delete from billing.accounts; select billing.switch_on()', 'run billing.copy_from_old');
end $$;
-- 25 (phase 4 fix 22: behaviour, not the function's text): pg_cron is made inside the rolled-back test
do $$
begin
  execute 'create extension if not exists pg_cron';
  perform billing.switch_on(pg_temp.t(0));
  perform pg_temp.ok('SW25 switch_on schedules the daily billing run',
    exists (select 1 from cron.job where jobname = 'billing-run' and command like '%billing/run%'));
  perform pg_temp.ok('SW25 ... and the history job', exists (select 1 from cron.job where jobname = 'billing-history'));
  -- the delete job waits for step 7, when the switch can no longer be undone (go-live review, Sol)
  perform pg_temp.ok('SW25 no delete job until start_delete_job', not exists (select 1 from cron.job where jobname = 'billing-delete'));
  perform billing.start_delete_job();
  perform pg_temp.ok('SW25 start_delete_job schedules it', exists (select 1 from cron.job where jobname = 'billing-delete'));
  -- an app tab opened before the switch: its old billing writes would land in tables nothing
  -- reads (a cancel there, then charged anyway): refused once switched (final review, Neon)
  perform pg_temp.ok('SW25 old billing writes closed to signed-in users',
    not has_function_privilege('authenticated', 'public.api_billing_change(text,text,bigint[])', 'execute')
    and not has_function_privilege('authenticated', 'public.api_billing_extras(integer,bigint[])', 'execute')
    and not has_function_privilege('authenticated', 'public.api_billing_keep(bigint)', 'execute')
    and not has_function_privilege('authenticated', 'public.api_billing_keep_set(bigint[])', 'execute')
    and not has_function_privilege('authenticated', 'public.api_billing_start_keep(bigint[])', 'execute')
    and not has_function_privilege('authenticated', 'public.api_plant_pick(bigint[])', 'execute'));
exception when others then perform pg_temp.ok('SW25 runs', false, sqlerrm);
end $$;
-- 26: the win-back lookup reads the old charges before the switch and the new tables after it
do $$
declare a uuid := pg_temp.acct('sw26'); u uuid; sw timestamptz; ref text; r record; mail bigint;
begin
  u := (select user_id from billing.accounts where id = a);
  select switched_at into sw from billing.switch_over;
  delete from billing.switch_over;                                         -- before the switch
  insert into public.email_queue (user_id, to_email, kind, key, status, sent_at)
  values (u, 'sw26@state.test', 'winback', 'winback:sw26', 'sent', pg_temp.t(1)) returning id into mail;
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, created_at, settled_at)
  values ('old_sw26', u, 'start', 'home', 'monthly', 4900, 'paid', pg_temp.t(2)::date, pg_temp.t(2)::date, pg_temp.t(2), pg_temp.t(2));
  select * into r from public.winback_return('old_sw26');
  perform pg_temp.eq('SW26 before the switch: from the old charges', r.email_id::text, mail::text);
  insert into billing.switch_over (switched_at) values (sw);               -- after it
  perform pg_temp.ok('SW26 after the switch: the old charges are not read', not exists (select 1 from public.winback_return('old_sw26')));
  perform pg_temp.link(a, 'sw26', '{990072601}', pg_temp.t(3));
  perform pg_temp.buy(a, 'home', 'month', '{990072601}', pg_temp.t(3));
  ref := (select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
           where i.account = a and pa.status = 'success' limit 1);
  select * into r from public.winback_return(ref);
  perform pg_temp.eq('SW26 after the switch: from the new tables', r.email_id::text, mail::text);
exception when others then perform pg_temp.ok('SW26 runs', false, sqlerrm);
end $$;

-- ---------------------------------------------------------------------------
-- Q phase 3 review fixes (money). Fixes 1, 2 and 7 are in F1.
-- ---------------------------------------------------------------------------
do $$
declare a uuid := pg_temp.acct('q3'); b uuid := pg_temp.acct('q4'); c uuid := pg_temp.acct('q5'); d uuid := pg_temp.acct('q6');
        e uuid := pg_temp.acct('q9'); f uuid := pg_temp.acct('q10'); g uuid := pg_temp.acct('q11');
        pe timestamptz; ref text; inv uuid; i1 jsonb; i2 jsonb; r jsonb; l uuid;
begin
  -- 3: a saved-card charge called abandoned is a failed try: the window starts on its due date
  pe := pg_temp.member(a, 'q3', 990050301);
  ref := pg_temp.job(a, pe, 'abandoned');
  perform pg_temp.eq('Q3 abandoned saved-card charge: a failed try', (select status from billing.payment_attempts where reference = ref), 'failed');
  perform pg_temp.eqt('Q3 ... the unpaid window starts on the due date', pg_temp.st(a, pe + interval '1 hour', 'past_due_since'), pe);

  -- 4: the owner's card page on the renewal, no clear answer: the window starts from the due date
  pe := pg_temp.member(b, 'q4', 990050401);
  inv := (billing.pay_now(b, pe + interval '1 minute')->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pe + interval '1 minute')->>'reference';
  perform pg_temp.answer(ref, 'unknown', pe + interval '2 minutes');
  perform billing.run(pe + interval '1 hour');
  perform pg_temp.eq('Q4 manual renewal unanswered: past due', pg_temp.st(b, pe + interval '1 hour', 'state'), 'past_due');
  perform pg_temp.eqt('Q4 ... from the due date', pg_temp.st(b, pe + interval '1 hour', 'past_due_since'), pe);

  -- 5: the same upgrade again gets the same bill
  pe := pg_temp.member(c, 'q5', 990050501);
  perform billing.link_login(c, 'sunsynk', 'q5', null, '[{"id":990050501},{"id":990050502},{"id":990050503}]', pg_temp.t(1));
  i1 := billing.upgrade(c, 'family', 0, '{990050501,990050502,990050503}', pg_temp.t(5));
  perform billing.begin_attempt((i1->>'invoice')::uuid, 'card_page', pg_temp.t(5));
  i2 := billing.upgrade(c, 'family', 0, '{990050501,990050502,990050503}', pg_temp.t(5) + interval '10 minutes');
  perform pg_temp.eq('Q5 upgrade again: the same bill', i2->>'invoice', i1->>'invoice');

  -- 6: an upgrade paid before the period ended, answered after its renewal bill exists: refunded
  pe := pg_temp.member(d, 'q6', 990050601);
  perform billing.link_login(d, 'sunsynk', 'q6', null, '[{"id":990050601},{"id":990050602},{"id":990050603}]', pg_temp.t(1));
  inv := (billing.upgrade(d, 'family', 0, '{990050601,990050602,990050603}', pg_temp.t(5))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(5))->>'reference';
  perform billing.run(pe);
  perform pg_temp.ok('Q6 the renewal bill was made', exists (select 1 from billing.invoices i join billing.subscriptions s on s.id = i.subscription
    where s.account = d and i.kind = 'renewal'));
  r := billing.apply_payment(ref, pg_temp.tx_ok(ref) || jsonb_build_object('paid_at', pg_temp.t(6)), pe + interval '1 hour');
  perform pg_temp.eq('Q6 late upgrade answer: refunded', r->>'action', 'refund');
  perform pg_temp.eq('Q6 ... as stale', r->>'reason', 'stale');

  -- 8: a try locks the bill's plants and the seats (the delete job skips locked plants).
  -- Left a text check: a lock shows only from a second session, and a second session cannot
  -- see this test's rows, which are never committed.
  perform pg_temp.ok('Q8 begin_attempt locks the plants', (select prosrc ~ 'lock_plants' from pg_proc p join pg_namespace n
    on n.oid = p.pronamespace where n.nspname = 'billing' and p.proname = 'begin_attempt'));

  -- 9: a hand refund told twice with no id: one row, no key error
  pe := pg_temp.member(e, 'q9', 990050901);
  ref := (select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
           where i.account = e and pa.status = 'success' limit 1);
  perform billing.record_refund_event(ref, 'pending', null, 1000, null, pg_temp.t(1), 'RREF_q9');
  begin
    perform billing.record_refund_event(ref, 'processed', null, 1000, null, pg_temp.t(2), 'RREF_q9');
    perform pg_temp.ok('Q9 the second event is no error', true);
  exception when others then
    perform pg_temp.ok('Q9 the second event is no error', false, sqlerrm);
  end;
  perform pg_temp.eq('Q9 one hand refund, processed', (select string_agg(status, ',') from billing.refunds where reference = ref and reason = 'manual'), 'processed');

  -- 10: a second dispute (new id) on the same payment is applied
  pe := pg_temp.member(f, 'q10', 990051001);
  ref := (select pa.reference from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
           where i.account = f and pa.status = 'success' limit 1);
  perform billing.record_dispute(ref, 'charge.dispute.resolve', 'won', false, 4900, pg_temp.t(2), 'D1_q10');
  r := billing.record_dispute(ref, 'charge.dispute.resolve', 'lost', true, 4900, pg_temp.t(3), 'D2_q10');
  perform pg_temp.ok('Q10 a new dispute after one resolved: applied', r->>'action' <> 'again');
  r := billing.record_dispute(ref, 'charge.dispute.resolve', 'lost', true, 4900, pg_temp.t(4), 'D2_q10');
  perform pg_temp.eq('Q10 the same dispute again: final', r->>'action', 'again');

  -- 11: a plant new on the login during a checkout does not refund it
  l := pg_temp.link(g, 'q11', '{990051101}', pg_temp.t(0));
  inv := (billing.start_checkout(g, 'home', 'month', 0, '{990051101}', pg_temp.t(0))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(0))->>'reference';
  perform billing.login_seen(l, '[{"id":990051101},{"id":990051102}]', pg_temp.t(0) + interval '1 minute');
  perform pg_temp.eq('Q11 checkout paid after the login list changed: applied',
    pg_temp.answer(ref, 'ok', pg_temp.t(0) + interval '2 minutes')->>'action', 'applied');
end $$;

-- ---------------------------------------------------------------------------
-- O emails (0247): each kind is queued by its cause and checked again when sent
-- ---------------------------------------------------------------------------
create function pg_temp.ob(p_acc uuid, p_key text) returns billing.outbox language sql as $$
  select * from billing.outbox where account = p_acc and key = p_key order by id desc limit 1
$$;
create function pg_temp.guard(p_acc uuid, p_key text, p_at timestamptz) returns text language sql as $$
  select coalesce(billing.outbox_guard(pg_temp.ob(p_acc, p_key), p_at), 'send')
$$;

-- O1 receipt: queued when the bill is paid, reads the frozen bill
do $$
declare a uuid := pg_temp.acct('o1'); o billing.outbox; w jsonb; b jsonb;
begin
  perform pg_temp.link(a, 'o1', '{990040101}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990040101}', pg_temp.t(0));
  o := pg_temp.ob(a, 'receipt');
  perform pg_temp.ok('O1 receipt queued for the paid bill', o.id is not null and o.invoice is not null);
  perform pg_temp.eq('O1 receipt sends', pg_temp.guard(a, 'receipt', pg_temp.t(0.01)), 'send');
  update billing.prices set amount_minor = 12345 where plan = 'home' and interval = 'month' and offer = 'launch';
  w := billing.outbox_take(500, pg_temp.t(0.01));
  select x into b from jsonb_array_elements(w) x where (x->>'id')::bigint = o.id;
  perform pg_temp.eq('O1 receipt amount from the frozen bill', b->'bill'->>'amount_minor', '4900');
  perform pg_temp.eq('O1 receipt names the plan', b->'bill'->>'plan_name', 'Home');
  perform pg_temp.ok('O1 receipt carries the reference and card', b->'bill'->>'reference' like 'psh\_%' and b->'bill'->>'last4' = 'main');
  perform pg_temp.eq('O1 state read at send time', b->'state'->>'state', 'active');
  update billing.prices set amount_minor = 4900 where plan = 'home' and interval = 'month' and offer = 'launch';
  perform billing.outbox_done(o.id, true, null, null, pg_temp.t(0.02));
  perform pg_temp.eq('O1 sent once', (select status from billing.outbox where id = o.id), 'sent');
  perform pg_temp.ok('O1 not handed out again', not exists (select 1 from jsonb_array_elements(billing.outbox_take(500, pg_temp.t(0.03))) x
    where (x->>'id')::bigint = o.id));
end $$;

-- O2 failed card: queued on the failed renewal try; dropped once that bill is paid
do $$
declare a uuid := pg_temp.acct('o2'); pe timestamptz; ref text;
begin
  pe := pg_temp.member(a, 'o2', 990040201);
  perform pg_temp.job(a, pe, 'fail');
  perform pg_temp.eq('O2 failed-card email queued, sends while unpaid', pg_temp.guard(a, 'payment_failed', pe + interval '1 hour'), 'send');
  ref := pg_temp.job(a, pe + interval '3 days', 'ok');
  perform pg_temp.eq('O2 paid before it went: dropped', pg_temp.guard(a, 'payment_failed', pe + interval '3 days 1 hour'), 'bill settled');
end $$;

-- O3 a cancel then its undo inside 2 minutes: only the undo goes
do $$
declare a uuid := pg_temp.acct('o3'); pe timestamptz;
begin
  pe := pg_temp.member(a, 'o3', 990040301);
  perform billing.cancel(a, pg_temp.t(2));
  perform pg_temp.eq('O3 cancel email waits 2 minutes', (pg_temp.ob(a, 'change_booked')).not_before::text,
    (pg_temp.t(2) + interval '2 minutes')::text);
  perform billing.undo_cancel(a, pg_temp.t(2) + interval '1 minute');
  perform pg_temp.eq('O3 the cancel email dropped', coalesce(billing.outbox_guard(pg_temp.ob(a, 'change_booked'), pg_temp.t(2.01)), 'send'), 'changed again');
  perform pg_temp.eq('O3 the undo email goes', pg_temp.guard(a, 'change_undone', pg_temp.t(2.01)), 'send');
  perform billing.downgrade(a, 'home', 0, '{}', pg_temp.t(3));
  perform pg_temp.eq('O3 same plan again is an undo',
    (select count(*)::text from billing.outbox where account = a and key = 'change_undone'), '2');
end $$;

-- O4 the free week: ends-soon queued 2 days before, dropped when paid; ended queued after
do $$
declare a uuid := pg_temp.acct('o4'); b uuid := pg_temp.acct('o4b');
begin
  perform pg_temp.link(a, 'o4', '{990040401}', pg_temp.t(0));
  perform pg_temp.choose(a, '{990040401}', pg_temp.t(0));
  perform billing.outbox_sweep(pg_temp.t(4));
  perform pg_temp.ok('O4 not before day 5', pg_temp.ob(a, 'trial_ends_soon') is null or (pg_temp.ob(a, 'trial_ends_soon')).id is null);
  perform billing.outbox_sweep(pg_temp.t(5.1));
  perform pg_temp.eq('O4 ends-soon queued on day 5', pg_temp.guard(a, 'trial_ends_soon', pg_temp.t(5.1)), 'send');
  perform billing.outbox_sweep(pg_temp.t(5.2));
  perform pg_temp.eq('O4 queued once', (select count(*)::text from billing.outbox where account = a and key = 'trial_ends_soon'), '1');
  perform pg_temp.buy(a, 'home', 'month', '{990040401}', pg_temp.t(5.3));
  perform pg_temp.eq('O4 paid: ends-soon dropped', pg_temp.guard(a, 'trial_ends_soon', pg_temp.t(5.4)), 'week over or paid');
  -- b: the week runs out unpaid
  perform pg_temp.link(b, 'o4b', '{990040402}', pg_temp.t(0));
  perform pg_temp.choose(b, '{990040402}', pg_temp.t(0));
  perform billing.outbox_sweep(pg_temp.t(7.1));
  perform pg_temp.eq('O4 week over: ended email', pg_temp.guard(b, 'trial_ended', pg_temp.t(7.1)), 'send');
  -- reminders switched off: dropped
  insert into public.email_prefs (user_id, reminders) select user_id, false from billing.accounts where id = b
  on conflict (user_id) do update set reminders = false;
  perform pg_temp.eq('O4 reminders off: dropped', pg_temp.guard(b, 'trial_ended', pg_temp.t(7.1)), 'reminders off');
end $$;

-- O5 history: delete-soon on day 14 after the end, dropped on a restart; deleted email
do $$
declare a uuid := pg_temp.acct('o5'); pe timestamptz;
begin
  pe := pg_temp.member(a, 'o5', 990040501);
  perform billing.cancel(a, pg_temp.t(1));
  perform billing.run(pe + interval '1 hour');
  perform pg_temp.eq('O5 plan ended email', pg_temp.guard(a, 'plan_ended', pe + interval '2 hours'), 'send');
  perform billing.outbox_sweep(pe + interval '14 days 1 hour');
  perform pg_temp.eq('O5 delete-soon on day 14', pg_temp.guard(a, 'history_delete_soon', pe + interval '14 days 2 hours'), 'send');
  perform pg_temp.eqt('O5 it names the delete date', to_timestamp((pg_temp.ob(a, 'history_delete_soon')).ref::bigint)::text,
    pe + interval '30 days');
  perform billing.switch_on(pg_temp.t(0));
  update billing.plants set history_purged_at = pe + interval '30 days 1 hour' where id = 990040501;
  perform pg_temp.eq('O5 history deleted email', pg_temp.guard(a, 'history_deleted', pe + interval '30 days 2 hours'), 'send');
  perform pg_temp.buy(a, 'home', 'month', '{990040501}', pe + interval '30 days 3 hours');
  perform pg_temp.eq('O5 restarted: delete-soon dropped', pg_temp.guard(a, 'history_delete_soon', pe + interval '30 days 4 hours'), 'expired');
  perform pg_temp.eq('O5 restarted: deleted email dropped', pg_temp.guard(a, 'history_deleted', pe + interval '30 days 4 hours'), 'plan running again');
end $$;

-- O6 screen state: names, prices, what letting a plant go does; the quote matches the upgrade bill
do $$
declare a uuid := pg_temp.acct('o6'); b uuid := pg_temp.acct('o6b'); s jsonb; q jsonb; inv jsonb;
begin
  perform pg_temp.link(a, 'o6', '{990040601,990040602,990040603}', pg_temp.t(0));
  perform pg_temp.link(b, 'o6b', '{990040601}', pg_temp.t(0));
  perform pg_temp.buy(b, 'home', 'month', '{990040601}', pg_temp.t(0), 'AUTH_o6b');
  perform pg_temp.buy(a, 'home', 'month', '{990040601,990040602}', pg_temp.t(0), 'AUTH_o6a');
  s := billing.screen_state(a, pg_temp.t(1));
  perform pg_temp.eq('O6 plan name', s->>'plan_name', 'Home');
  perform pg_temp.eq('O6 fits all three: Family', s->>'fit_all_name', 'Family');
  perform pg_temp.eq('O6 four prices', jsonb_array_length(s->'prices')::text, '4');
  perform pg_temp.eq('O6 the launch price kept', (select x->>'amount_minor' from jsonb_array_elements(s->'prices') x
    where x->>'plan' = 'family' and x->>'interval' = 'month'), '9900');
  perform pg_temp.eq('O6 shared plant kept by the other account', (select x->>'kept_elsewhere' from jsonb_array_elements(s->'plants') x
    where (x->>'plant')::bigint = 990040601), 'true');
  perform pg_temp.eq('O6 own plant not kept elsewhere', (select x->>'kept_elsewhere' from jsonb_array_elements(s->'plants') x
    where (x->>'plant')::bigint = 990040602), 'false');
  perform pg_temp.eqt('O6 history after a cancel', s->>'if_cancelled_delete_at', (pg_temp.sub(a)).period_end + interval '30 days');
  q := billing.quote(a, 'family', 'month', pg_temp.t(5));
  inv := billing.upgrade(a, 'family', 0, '{990040601,990040602,990040603}', pg_temp.t(5));
  perform pg_temp.eq('O6 quote is the upgrade bill', q->>'due_minor', inv->>'amount_minor');
  perform pg_temp.eq('O6 quote is an upgrade', q->>'kind', 'upgrade');
  perform pg_temp.eq('O6 downgrade quote: nothing to drop while the bill is unpaid', billing.quote(a, 'home', 'month', pg_temp.t(5))->>'drop', '0');
end $$;

-- O7 claims: first claim wins; the first choice after a claim is not counted
do $$
declare a uuid := pg_temp.acct('o7'); b uuid := pg_temp.acct('o7b');
begin
  perform billing.claim_plant(a, 990040701, 'Shared', 'sunsynk', pg_temp.t(0));
  perform pg_temp.fails('O7 second claim refused', format('select billing.claim_plant(%L, 990040701, ''x'', ''sunsynk'', %L)', b, pg_temp.t(0)), 'taken');
  perform pg_temp.choose(a, '{990040701}', pg_temp.t(0));
  perform pg_temp.eq('O7 a claim is a route', pg_temp.pp(a, pg_temp.t(0.1), 990040701, 'chosen'), 'true');
  perform billing.unclaim(a, '{990040701}', pg_temp.t(1));
  perform pg_temp.ok('O7 unclaimed: seat closed', not exists (select 1 from billing.seats where account = a and closed_at is null));
end $$;

-- O9 plant totals (sync-plant-energy) land only on a plant still read
do $$
declare rows jsonb := '[{"bucket":"month","period":"2026-11-01","pv_kwh":1,"load_kwh":2,"imp_kwh":0,"exp_kwh":0,"chg_kwh":0,"dischg_kwh":0,"synced_at":"2026-12-01T10:00:00Z"}]';
begin
  perform pg_temp.stored((select id from billing.logins where username = 'o1'));
  perform pg_temp.fails('O9 a plant nobody reads: refused',
    format('select public.q_upsert_plant_energy_v2(990040701, %s, %L, %L)', pg_temp.ver(990040701), rows, pg_temp.t(1)), 'not read now');
  perform pg_temp.fails('O9 a stale version: refused',
    format('select public.q_upsert_plant_energy_v2(990040101, %s, %L, %L)', pg_temp.ver(990040101) - 1, rows, pg_temp.t(1)), 'not read now');
  perform pg_temp.eq('O9 read now, its version: written',
    public.q_upsert_plant_energy_v2(990040101, pg_temp.ver(990040101), rows, pg_temp.t(1))::text, '1');
end $$;

-- O10 the old rules that still run follow the new state once live
do $$
declare a uuid := pg_temp.acct('o10'); u uuid;
begin
  u := (select user_id from billing.accounts where id = a);
  perform pg_temp.link(a, 'o10', '{990041001}', pg_temp.t(0));
  perform pg_temp.ok('O10 nothing chosen: the need-a-hand choose email waits', private.pick_waiting(u));
  perform pg_temp.ok('O10 a second login in none: refused', not public.link_login_allowed(u, 'o10-other'));
  perform pg_temp.ok('O10 the same login again: allowed', public.link_login_allowed(u, 'O10'));
  perform pg_temp.ok('O10 the old halves are not callable from the app',
    not has_function_privilege('authenticated', 'public.api_account_delete_old()', 'execute')
    and not has_function_privilege('authenticated', 'public.link_login_allowed_old(uuid, text)', 'execute'));
end $$;

-- O8 the sender's batch: every queued row either goes or is dropped with a reason
do $$
declare w jsonb;
begin
  w := billing.outbox_take(1000, pg_temp.t(60));
  perform pg_temp.ok('O8 a batch is handed out', jsonb_typeof(w) = 'array');
  perform pg_temp.ok('O8 dropped rows carry a reason', not exists (select 1 from billing.outbox where status = 'dropped' and drop_reason is null));
  perform pg_temp.ok('O8 every handed-out row has an email and state', not exists (select 1 from jsonb_array_elements(w) x
    where x->>'email' is null or x->'state' is null));
  perform pg_temp.ok('O8 not callable by signed-in users',
    not has_function_privilege('authenticated', 'billing.outbox_take(int, timestamptz)', 'execute')
    and has_function_privilege('authenticated', 'public.api_account_state()', 'execute')
    and not has_function_privilege('anon', 'public.api_account_state()', 'execute')
    and not has_function_privilege('authenticated', 'public.billing_links(text, jsonb)', 'execute'));
end $$;


-- ---------------------------------------------------------------------------
-- P4 phase 4 review fixes. Each block records its own failure (also an error), so a run
-- against the code before the fixes lists every one of them.
-- ---------------------------------------------------------------------------
-- 2: the edge functions read the chosen plants from the database (0260 drops plant_users.paused)
do $$
declare a uuid := pg_temp.acct('p402'); u uuid;
begin
  u := (select user_id from billing.accounts where id = a);
  perform pg_temp.link(a, 'p402', '{990070201,990070202}', pg_temp.t(0));
  perform pg_temp.pay(a, 'home', 'month', pg_temp.t(0));
  perform pg_temp.choose(a, '{990070201}', pg_temp.t(0));
  perform pg_temp.eq('P4-2 chosen plants once live: the open seats', public.chosen_plant_ids(u)::text, '{990070201}');
  perform pg_temp.ok('P4-2 ... for the service role only', not has_function_privilege('authenticated', 'public.chosen_plant_ids(uuid)', 'execute')
    and has_function_privilege('service_role', 'public.chosen_plant_ids(uuid)', 'execute'));
exception when others then perform pg_temp.ok('P4-2 runs', false, sqlerrm);
end $$;

-- 4: a new card on the card page turns active after it is saved: card-changed email
do $$
declare a uuid := pg_temp.acct('p404'); inv uuid; ref text;
begin
  perform pg_temp.member(a, 'p404', 990070401);
  inv := (billing.start_card_check(a, pg_temp.t(2))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(2))->>'reference';
  perform pg_temp.answer(ref, 'ok', pg_temp.t(2), 'AUTH_new4');
  perform pg_temp.eq('P4-4 a new card: card-changed email queued for it', (pg_temp.ob(a, 'card_changed')).ref,
    (billing.active_method(a)).id::text);
  perform pg_temp.eq('P4-4 ... and it sends', pg_temp.guard(a, 'card_changed', pg_temp.t(2.01)), 'send');
exception when others then perform pg_temp.ok('P4-4 runs', false, sqlerrm);
end $$;

-- 6: a login's email in another case is the same login
do $$
declare a uuid := pg_temp.acct('p406'); u uuid;
begin
  u := (select user_id from billing.accounts where id = a);
  perform billing.link_login(a, 'sunsynk', 'P406@Mail.test', null, '[{"id":990070601}]', pg_temp.t(0));
  perform billing.link_login(a, 'sunsynk', 'p406@mail.TEST', null, '[{"id":990070601},{"id":990070602}]', pg_temp.t(0.1));
  perform pg_temp.eq('P4-6 the same login in another case: still one login', (select count(*)::text from billing.logins where account = a), '1');
  perform pg_temp.ok('P4-6 ... and the state knows it', (public.billing_links('state',
    jsonb_build_object('user', u, 'username', 'P406@MAIL.TEST'))->>'login_known')::boolean);
exception when others then perform pg_temp.ok('P4-6 runs', false, sqlerrm);
end $$;

-- 7: an open card page can still take money: verified before a saved card is charged
do $$
declare a uuid := pg_temp.acct('p407'); pe timestamptz; inv uuid; ref text; r jsonb;
begin
  pe := pg_temp.member(a, 'p407', 990070701);
  inv := (billing.pay_now(a, pe + interval '1 minute')->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pe + interval '1 minute')->>'reference';
  r := billing.begin_attempt(inv, 'saved_card', pe + interval '2 minutes');
  perform pg_temp.ok('P4-7 an open card page: asked about first', r->'verify' @> to_jsonb(ref) and not r ? 'reference');
  perform pg_temp.eq('P4-7 ... the page is not let go', (select status from billing.payment_attempts where reference = ref), 'pending');
  perform pg_temp.answer(ref, 'abandoned', pe + interval '3 minutes');
  r := billing.begin_attempt(inv, 'saved_card', pe + interval '3 minutes');
  perform pg_temp.ok('P4-7 the page abandoned: the saved card is charged', r ? 'reference' and r->>'auth_ref' is not null);
exception when others then perform pg_temp.ok('P4-7 runs', false, sqlerrm);
end $$;

-- 8: a hard decline on an upgrade asks for no new card; the card email only while past due
do $$
declare a uuid := pg_temp.acct('p408'); inv uuid; ref text;
begin
  perform pg_temp.member(a, 'p408', 990070801);
  perform billing.link_login(a, 'sunsynk', 'p408', null, '[{"id":990070801},{"id":990070802},{"id":990070803}]', pg_temp.t(1));
  inv := (billing.upgrade(a, 'family', 0, '{990070801,990070802,990070803}', pg_temp.t(5))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'saved_card', pg_temp.t(5))->>'reference';
  perform pg_temp.answer(ref, 'hard', pg_temp.t(5));
  perform pg_temp.ok('P4-8 a hard decline on an upgrade: no card email', not exists (select 1 from billing.outbox where account = a and key = 'card_update'));
  insert into billing.outbox (account, key, invoice, dedupe_key, not_before, created_at)
  values (a, 'card_update', inv, 'card_update:p408', pg_temp.t(5), pg_temp.t(5));
  perform pg_temp.eq('P4-8 the card email waits for an unpaid renewal', pg_temp.guard(a, 'card_update', pg_temp.t(5.01)), 'not past due');
exception when others then perform pg_temp.ok('P4-8 runs', false, sqlerrm);
end $$;

-- 9: a refund written as processed is emailed, naming the card the payment came from
do $$
declare a uuid := pg_temp.acct('p409'); inv uuid; ref text; att uuid; rid uuid; o billing.outbox; b jsonb;
begin
  perform pg_temp.member(a, 'p409', 990070901);
  att := (select pa.id from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
           where i.account = a and i.kind = 'purchase' and pa.status = 'success');
  inv := (billing.start_card_check(a, pg_temp.t(2))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(2))->>'reference';
  perform pg_temp.answer(ref, 'ok', pg_temp.t(2), 'AUTH_new9');
  insert into billing.refunds (attempt, reference, account, amount_minor, currency, reason, status, created_at, updated_at)
  values (att, 'RREF_p409', a, 1000, 'ZAR', 'manual', 'processed', pg_temp.t(3), pg_temp.t(3)) returning id into rid;
  o := pg_temp.ob(a, 'refund');
  perform pg_temp.eq('P4-9 a refund written processed: emailed', o.ref, rid::text);
  select x into b from jsonb_array_elements(billing.outbox_take(500, pg_temp.t(3.01))) x where (x->>'id')::bigint = o.id;
  perform pg_temp.eq('P4-9 ... naming the paid card, not the new one', b->'refund'->>'last4', 'p409');
exception when others then perform pg_temp.ok('P4-9 runs', false, sqlerrm);
end $$;

-- 11: a bill keeps the plan's name it was made with
do $$
declare a uuid := pg_temp.acct('p411'); o billing.outbox; b jsonb;
begin
  perform pg_temp.link(a, 'p411', '{990071101}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990071101}', pg_temp.t(0));
  update billing.plans set name = 'Home Plus' where code = 'home';
  perform pg_temp.eq('P4-11 Payments: the name the bill was made with', billing.screen_state(a, pg_temp.t(1))->'bills'->0->>'plan_name', 'Home');
  o := pg_temp.ob(a, 'receipt');
  select x into b from jsonb_array_elements(billing.outbox_take(500, pg_temp.t(0.01))) x where (x->>'id')::bigint = o.id;
  perform pg_temp.eq('P4-11 the receipt too', b->'bill'->>'plan_name', 'Home');
  update billing.plans set name = 'Home' where code = 'home';
exception when others then perform pg_temp.ok('P4-11 runs', false, sqlerrm);
end $$;

-- 14: the cancel date only when a chosen plant's history goes with it; still there once booked
do $$
declare a uuid := pg_temp.acct('p414a'); b uuid := pg_temp.acct('p414b'); c uuid := pg_temp.acct('p414c'); pe timestamptz;
begin
  perform pg_temp.link(a, 'p414a', '{990071401}', pg_temp.t(0));
  perform pg_temp.link(b, 'p414b', '{990071401}', pg_temp.t(0));
  perform pg_temp.buy(b, 'home', 'month', '{990071401}', pg_temp.t(0), 'AUTH_p414b');
  perform pg_temp.buy(a, 'home', 'month', '{990071401}', pg_temp.t(0), 'AUTH_p414a');
  perform pg_temp.eq('P4-14 every chosen plant kept by another account: no delete date',
    billing.screen_state(a, pg_temp.t(1))->>'if_cancelled_delete_at', null);
  pe := pg_temp.member(c, 'p414c', 990071402);
  perform billing.cancel(c, pg_temp.t(2));
  perform pg_temp.eqt('P4-14 cancel booked: the delete date stays for the email',
    billing.screen_state(c, pg_temp.t(2.01))->>'if_cancelled_delete_at', pe + interval '30 days');
exception when others then perform pg_temp.ok('P4-14 runs', false, sqlerrm);
end $$;

-- 15: kept-until and the reminder read the chosen plants only, the earliest date
do $$
declare a uuid := pg_temp.acct('p415a'); b uuid := pg_temp.acct('p415b');
begin
  perform pg_temp.link(a, 'p415a', '{990071501,990071502}', pg_temp.t(0));
  perform pg_temp.choose(a, '{990071501}', pg_temp.t(0));                -- week ends day 7
  perform pg_temp.link(b, 'p415b', '{990071502}', pg_temp.t(3));
  perform pg_temp.choose(b, '{990071502}', pg_temp.t(3));                -- week ends day 10: kept later
  perform pg_temp.eqt('P4-15 kept until: the chosen plant''s date', billing.screen_state(a, pg_temp.t(11))->>'history_kept_until',
    pg_temp.t(37));
  perform billing.outbox_sweep(pg_temp.t(21) + interval '1 hour');
  perform pg_temp.eqt('P4-15 the reminder names it', to_timestamp((pg_temp.ob(a, 'history_delete_soon')).ref::bigint)::text, pg_temp.t(37));
exception when others then perform pg_temp.ok('P4-15 runs', false, sqlerrm);
end $$;

-- 16: a week that ended long before the first sweep (the switch-over) gets no week-ended email
do $$
declare a uuid := pg_temp.acct('p416');
begin
  perform pg_temp.link(a, 'p416', '{990071601}', pg_temp.t(0));
  perform pg_temp.choose(a, '{990071601}', pg_temp.t(0));
  perform billing.outbox_sweep(pg_temp.t(20));
  perform pg_temp.ok('P4-16 week over 13 days ago: no week-ended email', (pg_temp.ob(a, 'trial_ended')).id is null);
exception when others then perform pg_temp.ok('P4-16 runs', false, sqlerrm);
end $$;

-- 17: a claimed plant keeps its name (no login lists it)
do $$
declare a uuid := pg_temp.acct('p417');
begin
  perform billing.claim_plant(a, 990071701, 'Gran''s house', 'sunsynk', pg_temp.t(0));
  perform pg_temp.eq('P4-17 a claimed plant is named', pg_temp.pp(a, pg_temp.t(0.1), 990071701, 'name'), 'Gran''s house');
exception when others then perform pg_temp.ok('P4-17 runs', false, sqlerrm);
end $$;

-- 19: the delete job checks with one clock after its lock: a payment started after the job's
-- start holds the plant. Real time here (clock_timestamp), not the test's December clock.
do $$
declare a uuid := pg_temp.acct('p419'); t0 timestamptz := now() - interval '60 days'; inv uuid;
begin
  perform pg_temp.link(a, 'p419', '{990071901}', t0);
  perform pg_temp.choose(a, '{990071901}', t0);                          -- kept until 23 days ago
  perform pg_temp.agg(990071901, t0 + interval '1 day');
  inv := (billing.start_checkout(a, 'home', 'month', 0, '{990071901}', clock_timestamp())->>'invoice')::uuid;
  perform billing.begin_attempt(inv, 'card_page', clock_timestamp());
  perform billing.delete_due(now() - interval '1 hour');
  perform pg_temp.ok('P4-19 a payment after the job''s start: the history waits', pg_temp.has_agg(990071901)
    and (select history_purged_at is null from billing.plants where id = 990071901));
exception when others then perform pg_temp.ok('P4-19 runs', false, sqlerrm);
end $$;

-- 20: the login-check wrapper is not callable from the app
do $$
begin
  perform pg_temp.ok('P4-20 link_login_allowed: service role only',
    not has_function_privilege('authenticated', 'public.link_login_allowed(uuid, text)', 'execute')
    and not has_function_privilege('anon', 'public.link_login_allowed(uuid, text)', 'execute')
    and has_function_privilege('service_role', 'public.link_login_allowed(uuid, text)', 'execute'));
exception when others then perform pg_temp.ok('P4-20 runs', false, sqlerrm);
end $$;
-- ===========================================================================
-- Final review fixes (FR). Each block fails on ddd6e1c.
-- ===========================================================================
-- FR1 a replaced card page Paystack could still settle blocks a saved-card charge
do $$
declare a uuid := pg_temp.acct('fr1'); b uuid := pg_temp.acct('fr1b'); pe timestamptz; inv uuid; inv2 uuid; ref text; r jsonb;
begin
  perform pg_temp.member(a, 'fr1', 990090101);
  perform billing.link_login(a, 'sunsynk', 'fr1', null, '[{"id":990090101},{"id":990090102},{"id":990090103}]', pg_temp.t(1));
  inv := (billing.upgrade(a, 'family', 0, '{990090101,990090102}', pg_temp.t(5))->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pg_temp.t(5))->>'reference';
  inv2 := (billing.upgrade(a, 'family', 0, '{990090101,990090102,990090103}', pg_temp.t(5) + interval '1 minute')->>'invoice')::uuid;
  perform pg_temp.ok('FR1 the old page is never handed back', inv2 <> inv
    and (select replaced_at is not null and status = 'pending' from billing.payment_attempts where reference = ref));
  r := billing.begin_attempt(inv2, 'saved_card', pg_temp.t(5) + interval '2 minutes');
  perform pg_temp.ok('FR1 a replaced page still payable: asked about first, nothing charged',
    r->'verify' @> to_jsonb(ref) and not r ? 'reference');
  perform pg_temp.answer(ref, 'pending', pg_temp.t(5) + interval '3 minutes');
  r := billing.begin_attempt(inv2, 'saved_card', pg_temp.t(5) + interval '3 minutes');
  perform pg_temp.ok('FR1 ... still payable after the verify: still waits', r ? 'verify' and not r ? 'reference');
  perform pg_temp.answer(ref, 'abandoned', pg_temp.t(5) + interval '4 minutes');
  r := billing.begin_attempt(inv2, 'saved_card', pg_temp.t(5) + interval '4 minutes');
  perform pg_temp.ok('FR1 Paystack says it cannot pay: the saved card is charged', r ? 'reference');

  -- the renewal job waits too
  pe := pg_temp.member(b, 'fr1b', 990090111);
  perform billing.link_login(b, 'sunsynk', 'fr1b', null, '[{"id":990090111},{"id":990090112},{"id":990090113}]', pg_temp.t(1));
  inv := (billing.upgrade(b, 'family', 0, '{990090111,990090112}', pe - interval '2 days')->>'invoice')::uuid;
  ref := billing.begin_attempt(inv, 'card_page', pe - interval '2 days')->>'reference';
  perform billing.upgrade(b, 'family', 0, '{990090111,990090112,990090113}', pe - interval '2 days' + interval '1 minute');
  perform pg_temp.ok('FR1 renewal: a replaced page still payable holds the charge', pg_temp.job(b, pe) is null);
  perform pg_temp.answer(ref, 'abandoned', pe + interval '1 hour');
  perform pg_temp.ok('FR1 renewal: charged once Paystack says it cannot pay', pg_temp.job(b, pe + interval '1 hour') is not null);
exception when others then perform pg_temp.ok('FR1 runs', false, sqlerrm);
end $$;

-- FR2 a cancelled plan has no next billing date to switch
do $$
declare a uuid := pg_temp.acct('fr2');
begin
  perform pg_temp.member(a, 'fr2', 990090201);
  perform billing.cancel(a, pg_temp.t(2));
  perform pg_temp.fails('FR2 switch_interval refuses a cancelled plan',
    format('select billing.switch_interval(%L, ''year'', %L)', a, pg_temp.t(3)), 'cancelled');
exception when others then perform pg_temp.ok('FR2 runs', false, sqlerrm);
end $$;

-- FR3 the same login typed in another case updates the stored row
do $$
declare a uuid := pg_temp.acct('fr3'); u uuid; l1 uuid; l2 uuid;
begin
  u := (select user_id from billing.accounts where id = a);
  l1 := public.account_upsert(u, 'FR3@Mail.test', 'tok1', 1);
  l2 := public.account_upsert(u, 'fr3@mail.TEST', 'tok2', 2);
  perform pg_temp.ok('FR3 another case: the same stored login, updated in place', l1 = l2
    and (select count(*) = 1 from private.sunsynk_accounts where user_id = u)
    and (select access_token = 'tok2' from private.sunsynk_accounts where id = l1));
exception when others then perform pg_temp.ok('FR3 runs', false, sqlerrm);
end $$;

-- FR4 live linking is one transaction: a refused login leaves no row and no secret
do $$
declare a uuid := pg_temp.acct('fr4'); u uuid; l uuid; secrets bigint;
begin
  u := (select user_id from billing.accounts where id = a);
  l := public.link_login_live(u, 'fr4@mail.test', 'tok', 1, 'refresh-fr4', '[{"id":990090401,"name":"A"}]');
  perform pg_temp.ok('FR4 a new login: stored, its secret kept, in billing under the same id',
    exists (select 1 from billing.logins where id = l and account = a)
    and (select refresh_secret_id is not null from private.sunsynk_accounts where id = l));
  perform pg_temp.choose(a, '{990090401}', now());                       -- the week starts: one login only
  secrets := (select count(*) from vault.secrets);
  perform pg_temp.fails('FR4 a second login in the week: refused',
    format('select public.link_login_live(%L, ''fr4-other@mail.test'', ''tok'', 1, ''refresh-x'', ''[{"id":990090402}]'')', u), 'one login');
  perform pg_temp.ok('FR4 ... no login row and no secret left behind',
    not exists (select 1 from private.sunsynk_accounts where user_id = u and sunsynk_username = 'fr4-other@mail.test')
    and (select count(*) from vault.secrets) = secrets);
exception when others then perform pg_temp.ok('FR4 runs', false, sqlerrm);
end $$;

-- FR5 a share claim: billing decides and the link row is written with it
-- FR6 the share removed in the inverter cloud releases the claim
do $$
declare a uuid := pg_temp.acct('fr5a'); b uuid := pg_temp.acct('fr5b'); c uuid := pg_temp.acct('fr5c');
        ua uuid; ub uuid; uc uuid; l uuid; sh uuid;
begin
  select user_id into ua from billing.accounts where id = a;
  select user_id into ub from billing.accounts where id = b;
  select user_id into uc from billing.accounts where id = c;
  sh := pg_temp.share_login();
  -- A reads plant 990090501 through A's own login
  l := pg_temp.link(a, 'fr5a', '{990090501}', pg_temp.t(0)); perform pg_temp.stored(l);
  insert into public.plant_users (plant_id, user_id, account_id, plant_name) values (990090501, ua, l, 'Mine');
  perform pg_temp.eq('FR5 another user''s own-login row does not block the claim',
    public.share_claim_live(ub, sh, 990090501, 'Shared'), 'claimed');
  perform pg_temp.ok('FR5 ... billing and the link row agree',
    (select account = b from billing.plant_claims where plant = 990090501)
    and exists (select 1 from public.plant_users where plant_id = 990090501 and user_id = ub and via_share));
  perform pg_temp.fails('FR5 a second claimant: taken',
    format('select public.share_claim_live(%L, %L, 990090501, ''x'')', uc, sh), 'taken');
  perform pg_temp.ok('FR5 ... and no link row for it', not exists (select 1 from public.plant_users where plant_id = 990090501 and user_id = uc));
  -- B's week over unpaid: ended. A claim B holds is repaired; a new plant is refused.
  update billing.accounts set trial_started_at = now() - interval '10 days', trial_ends_at = now() - interval '3 days' where id = b;
  delete from public.plant_users where plant_id = 990090501 and user_id = ub;
  perform pg_temp.eq('FR5 ended: the claim it holds is repaired', public.share_claim_live(ub, sh, 990090501, 'Shared'), 'claimed');
  perform pg_temp.fails('FR5 ended: a new plant is refused',
    format('select public.share_claim_live(%L, %L, 990090502, ''x'')', ub, sh), 'without a plan');

  -- FR6: gone from the share login's list for over 50 minutes
  update public.plant_users set share_missing_at = now() - interval '1 hour' where plant_id = 990090501 and user_id = ub;
  perform public.share_sync(sh, '{}');
  perform pg_temp.ok('FR6 the share removed: the billing claim goes', not exists (select 1 from billing.plant_claims where plant = 990090501));
  perform pg_temp.eq('FR6 ... and someone else may claim it', public.share_claim_live(uc, sh, 990090501, 'Shared'), 'claimed');
exception when others then perform pg_temp.ok('FR5 runs', false, sqlerrm);
end $$;

-- FR7 removing a login or a claim deletes the history nothing keeps, at once
do $$
declare a uuid := pg_temp.acct('fr7'); b uuid := pg_temp.acct('fr7b'); l uuid;
begin
  l := pg_temp.link(a, 'fr7', '{990090701}', pg_temp.t(0));
  perform pg_temp.pay(a, 'home', 'month', pg_temp.t(0));
  perform pg_temp.choose(a, '{990090701}', pg_temp.t(0));
  perform pg_temp.agg(990090701, pg_temp.t(0));
  perform billing.remove_login(a, l, pg_temp.t(1));
  perform pg_temp.ok('FR7 remove_login: history deleted now', not pg_temp.has_agg(990090701)
    and (select history_purged_at is not null from billing.plants where id = 990090701));
  perform billing.claim_plant(b, 990090702, 'Shared', 'sunsynk', pg_temp.t(0));
  perform pg_temp.pay(b, 'home', 'month', pg_temp.t(0));
  perform pg_temp.choose(b, '{990090702}', pg_temp.t(0));
  perform pg_temp.agg(990090702, pg_temp.t(0));
  perform billing.unclaim(b, '{990090702}', pg_temp.t(1));
  perform pg_temp.ok('FR7 unclaim: history deleted now', not pg_temp.has_agg(990090702)
    and (select history_purged_at is not null from billing.plants where id = 990090702));
exception when others then perform pg_temp.ok('FR7 runs', false, sqlerrm);
end $$;

-- FR9 the cancel date compares the deadlines after the cancel, not who keeps the plant today
do $$
declare a uuid := pg_temp.acct('fr9a'); b uuid := pg_temp.acct('fr9b');
begin
  perform pg_temp.link(b, 'fr9b', '{990090901}', pg_temp.t(0));
  perform pg_temp.choose(b, '{990090901}', pg_temp.t(0));                 -- b's free week, to day 7
  perform pg_temp.link(a, 'fr9a', '{990090901}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990090901}', pg_temp.t(0), 'AUTH_fr9a');
  perform pg_temp.eqt('FR9 kept by a free week that ends first: this plan''s date decides',
    billing.screen_state(a, pg_temp.t(1))->>'if_cancelled_delete_at', (pg_temp.sub(a)).period_end + interval '30 days');
exception when others then perform pg_temp.ok('FR9 runs', false, sqlerrm);
end $$;

-- FR11 a card made active again gets its own card-changed email, timed by the activation
do $$
declare a uuid := pg_temp.acct('fr11'); c1 text; c2 text;
begin
  perform pg_temp.member(a, 'fr11', 990091101);                          -- card AUTH_fr11 on day 0
  perform billing.save_method(a, pg_temp.tx_ok('x', 'AUTH_fr11b'), pg_temp.t(3));
  perform billing.save_method(a, pg_temp.tx_ok('x', 'AUTH_fr11'), pg_temp.t(10));
  perform billing.save_method(a, pg_temp.tx_ok('x', 'AUTH_fr11b'), pg_temp.t(20));
  select id::text into c1 from billing.payment_methods where auth_ref = 'AUTH_fr11';
  select id::text into c2 from billing.payment_methods where auth_ref = 'AUTH_fr11b';
  perform pg_temp.ok('FR11 the old card again: emailed from its activation',
    exists (select 1 from billing.outbox where account = a and key = 'card_changed' and ref = c1
               and not_before = pg_temp.t(10) and expires_at = pg_temp.t(12)));
  perform pg_temp.eq('FR11 one email per activation', (select count(*)::text from billing.outbox
    where account = a and key = 'card_changed' and ref = c2), '2');
exception when others then perform pg_temp.ok('FR11 runs', false, sqlerrm);
end $$;

-- FR17 the switch-over pause: first no new old payment, then no old billing write at all
do $$
declare ok boolean := true;
begin
  perform billing.pause_old('new_payments');
  perform pg_temp.fails('FR17 new_payments: no old payment starts',
    'insert into private.billing_charges (reference) values (''psh_paused'')', 'paused for an update');
  begin
    update private.billing_charges set status = status where false;      -- settling open ones goes on
  exception when others then ok := false;
  end;
  perform pg_temp.ok('FR17 new_payments: open payments can still be settled', ok);
  perform billing.pause_old('all');
  perform pg_temp.fails('FR17 all: no old billing write', 'update private.billing set plan = plan where false', 'paused for an update');
  perform pg_temp.fails('FR17 all: no old plant pick', 'delete from private.plant_picks where false', 'paused for an update');
  perform billing.resume_old();
  ok := true;
  begin
    update private.billing set plan = plan where false;
  exception when others then ok := false;
  end;
  perform pg_temp.ok('FR17 resumed: old writes go through', ok);
exception when others then perform pg_temp.ok('FR17 runs', false, sqlerrm);
end $$;

-- ===========================================================================
-- Verify review fixes (each block fails without its fix; S14-S16 hold the copy's)
-- ===========================================================================
-- V1 a replaced card page Paystack still calls pending after 24 h stays pending and blocks
--    the saved-card charge (fix 1)
do $$
declare a uuid := pg_temp.acct('v1'); i1 uuid; i2 uuid; ref text; r jsonb;
begin
  perform pg_temp.link(a, 'v1', '{990100101,990100102,990100103}', pg_temp.t(0));
  perform pg_temp.buy(a, 'home', 'month', '{990100101}', pg_temp.t(0), 'AUTH_v1');
  i1 := (billing.upgrade(a, 'family', 0, '{990100101,990100102}', pg_temp.t(5))->>'invoice')::uuid;
  ref := billing.begin_attempt(i1, 'card_page', pg_temp.t(5))->>'reference';
  i2 := (billing.upgrade(a, 'family', 0, '{990100101,990100102,990100103}', pg_temp.t(5))->>'invoice')::uuid;
  perform pg_temp.answer(ref, 'pending', pg_temp.t(5) + interval '25 hours');
  perform pg_temp.eq('V1 a card page still pending after 24 h: pending, not failed',
    (select status from billing.payment_attempts where reference = ref), 'pending');
  r := billing.begin_attempt(i2, 'saved_card', pg_temp.t(5) + interval '25 hours');
  perform pg_temp.ok('V1 ... the saved card is not charged while it may still pay', r ? 'verify' and r->'verify' ? ref, r::text);
  perform pg_temp.answer(ref, 'abandoned', pg_temp.t(5) + interval '26 hours');
  perform pg_temp.ok('V1 Paystack says abandoned: the saved card is charged',
    billing.begin_attempt(i2, 'saved_card', pg_temp.t(5) + interval '26 hours') ? 'reference');
exception when others then perform pg_temp.ok('V1 runs', false, sqlerrm);
end $$;

-- V3 an old write holds the freeze lock to its commit; pause_old takes it exclusive, so it
--    waits for writes under way (fix 3). V4 the pause check needs no right on billing (fix 4)
do $$
declare ok boolean := true; held text;
begin
  update private.plant_week set started_at = started_at where false;
  select string_agg(mode, ',') into held from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()
     and classid = 7 and objid = 641 and granted;
  perform pg_temp.ok('V3 an old write takes the shared freeze lock', held like '%ShareLock%', held);
  perform billing.pause_old('new_payments');
  perform pg_temp.ok('V3 pause_old takes it exclusive', exists (select 1 from pg_locks where locktype = 'advisory'
    and pid = pg_backend_pid() and classid = 7 and objid = 641 and mode = 'ExclusiveLock' and granted));
  perform billing.resume_old();
  perform pg_temp.ok('V4 the pause check runs as its owner, with an empty search path',
    (select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = 'private.old_billing_paused()'::regprocedure));
  perform pg_temp.ok('V4 billing.old_pause closed to the app roles',
    not has_table_privilege('authenticated', 'billing.old_pause', 'select') and not has_table_privilege('anon', 'billing.old_pause', 'select')
    and not has_table_privilege('public', 'billing.old_pause', 'select'));
  revoke all on table billing.old_pause from service_role;
  grant usage on schema private to service_role;                         -- as an edge function's write would have it
  set local role service_role;
  begin
    update private.plant_week set started_at = started_at where false;
  exception when others then ok := false; held := sqlerrm;
  end;
  reset role;
  perform pg_temp.ok('V4 service_role writes an old table while nothing is paused', ok, held);
exception when others then reset role; perform pg_temp.ok('V3 runs', false, sqlerrm);
end $$;

-- V12 a share removed in the inverter cloud: reading stops, the seat and the history stay (fix 12)
do $$
declare b uuid := pg_temp.acct('v12'); ub uuid; sh uuid;
begin
  select user_id into ub from billing.accounts where id = b;
  sh := pg_temp.share_login();
  perform pg_temp.eq('V12 claimed', public.share_claim_live(ub, sh, 990101201, 'Shared'), 'claimed');
  perform pg_temp.pay(b, 'home', 'month', now() - interval '1 day');
  perform pg_temp.choose(b, '{990101201}', now() - interval '1 day');
  perform pg_temp.agg(990101201, now() - interval '1 hour');
  update public.plant_users set share_missing_at = now() - interval '1 hour' where plant_id = 990101201 and user_id = ub;
  perform public.share_sync(sh, '{}');
  perform pg_temp.ok('V12 the claim goes', not exists (select 1 from billing.plant_claims where plant = 990101201));
  perform pg_temp.eq('V12 reading stops', pg_temp.pp(b, now(), 990101201, 'read_now'), 'false');
  perform pg_temp.ok('V12 the seat stays', exists (select 1 from billing.seats where account = b and plant = 990101201 and closed_at is null));
  perform pg_temp.ok('V12 the history stays', pg_temp.has_agg(990101201)
    and (select history_purged_at is null from billing.plants where id = 990101201));
  perform pg_temp.ok('V12 logged', exists (select 1 from billing.account_events where account = b and actor = 'share_gone' and kind = 'unclaim'));
exception when others then perform pg_temp.ok('V12 runs', false, sqlerrm);
end $$;

-- V13 a share claim on a plant the user reads through their own login: 'yours', no claim row (fix 13)
do $$
declare a uuid := pg_temp.acct('v13'); ua uuid; l uuid; sh uuid;
begin
  select user_id into ua from billing.accounts where id = a;
  sh := pg_temp.share_login();
  l := pg_temp.link(a, 'v13', '{990101301}', pg_temp.t(0)); perform pg_temp.stored(l);
  insert into public.plant_users (plant_id, user_id, account_id, plant_name) values (990101301, ua, l, 'Mine');
  perform pg_temp.eq('V13 own login: yours', public.share_claim_live(ua, sh, 990101301, 'Mine'), 'yours');
  perform pg_temp.ok('V13 ... and no claim row without a share route', not exists (select 1 from billing.plant_claims where plant = 990101301));
exception when others then perform pg_temp.ok('V13 runs', false, sqlerrm);
end $$;

-- V15 a chosen plant whose history is already deleted does not give the cancel a date (fix 15)
do $$
declare a uuid := pg_temp.acct('v15');
begin
  perform pg_temp.member(a, 'v15', 990101501);
  update billing.plants set history_purged_at = pg_temp.t(1) where id = 990101501;
  perform pg_temp.eq('V15 only a purged plant chosen: no cancel date',
    coalesce(billing.screen_state(a, pg_temp.t(2))->>'if_cancelled_delete_at', 'null'), 'null');
exception when others then perform pg_temp.ok('V15 runs', false, sqlerrm);
end $$;

-- V16 another account's booked drop keeps a plant to its billing date only; a grant-only
--     account to its grant's end (fix 16)
do $$
declare b uuid := pg_temp.acct('v16b'); c uuid := pg_temp.acct('v16c'); pe timestamptz;
begin
  pe := pg_temp.member(b, 'v16b', 990101601);
  update billing.seats set drop_at_period_end = true where account = b and plant = 990101601;
  perform pg_temp.eqt('V16 a booked drop: its billing date, no days after',
    billing.kept_by_others_until(gen_random_uuid(), 990101601, pg_temp.t(1))::text, pe);
  perform pg_temp.link(c, 'v16c', '{990101602}', pg_temp.t(0));
  insert into billing.grants (account, places, reason, starts_at, ends_at) values (c, 5, 'comped', pg_temp.t(0), pg_temp.t(40));
  perform pg_temp.choose(c, '{990101602}', pg_temp.t(0));
  perform pg_temp.eqt('V16 grant only: its end, then the days kept',
    billing.kept_by_others_until(gen_random_uuid(), 990101602, pg_temp.t(1))::text, pg_temp.t(70));
exception when others then perform pg_temp.ok('V16 runs', false, sqlerrm);
end $$;

-- V17 cards switched back and forth within the hour: one email, for the card active now (fix 17)
do $$
declare a uuid := pg_temp.acct('v17'); c2 text; o1 billing.outbox; o2 billing.outbox;
begin
  perform pg_temp.member(a, 'v17', 990101701);                            -- AUTH_v17 on day 0
  perform billing.save_method(a, pg_temp.tx_ok('x', 'AUTH_v17b'), pg_temp.t(3));
  perform billing.save_method(a, pg_temp.tx_ok('x', 'AUTH_v17'), pg_temp.t(3) + interval '1 hour');
  perform billing.save_method(a, pg_temp.tx_ok('x', 'AUTH_v17b'), pg_temp.t(3) + interval '2 hours');
  select id::text into c2 from billing.payment_methods where auth_ref = 'AUTH_v17b';
  select * into o1 from billing.outbox where account = a and key = 'card_changed' and ref = c2 and not_before = pg_temp.t(3);
  select * into o2 from billing.outbox where account = a and key = 'card_changed' and ref = c2 and not_before = pg_temp.t(3) + interval '2 hours';
  perform pg_temp.eq('V17 the card active again later: its first email dropped', billing.outbox_guard(o1, pg_temp.t(3) + interval '3 hours'), 'card replaced');
  perform pg_temp.eq('V17 ... its latest one sent', coalesce(billing.outbox_guard(o2, pg_temp.t(3) + interval '3 hours'), 'send'), 'send');
exception when others then perform pg_temp.ok('V17 runs', false, sqlerrm);
end $$;

-- ===========================================================================
-- Verify 2 fixes (each block fails without its fix; S17 holds the copy's)
-- ===========================================================================
-- W3 a share removed: the plant leaves what the user sees and what the emails read; it
--    comes back with the share (fix 3). W4 it keeps its name and may stay chosen (fix 4)
do $$
declare b uuid := pg_temp.acct('w3'); ub uuid; sh uuid; r jsonb;
begin
  select user_id into ub from billing.accounts where id = b;
  sh := pg_temp.share_login();
  perform public.share_claim_live(ub, sh, 990110301, 'Gran');
  perform pg_temp.pay(b, 'home', 'month', now() - interval '1 day');
  perform pg_temp.choose(b, '{990110301}', now() - interval '1 day');
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  perform pg_temp.ok('W3 shared and chosen: seen', 990110301 = any (public.chosen_plant_ids(ub))
    and exists (select 1 from public.my_plant_ids() x where x = 990110301));
  update public.plant_users set share_missing_at = now() - interval '1 hour' where plant_id = 990110301 and user_id = ub;
  perform public.share_sync(sh, '{}');
  perform pg_temp.ok('W3 share removed: the emails no longer read it', not 990110301 = any (public.chosen_plant_ids(ub)));
  perform pg_temp.ok('W3 ... and the user no longer sees it', not exists (select 1 from public.my_plant_ids() x where x = 990110301));
  perform pg_temp.eq('W4 ... it keeps its name', pg_temp.pp(b, now(), 990110301, 'name'), 'Gran');
  insert into billing.plant_claims (plant, account, claimed_at, plant_name) values (990110301, b, now(), 'Gran');
  perform pg_temp.ok('W3 the share back: seen again', 990110301 = any (public.chosen_plant_ids(ub))
    and exists (select 1 from public.my_plant_ids() x where x = 990110301));
  perform set_config('request.jwt.claims', '', true);
exception when others then perform set_config('request.jwt.claims', '', true); perform pg_temp.ok('W3 runs', false, sqlerrm);
end $$;

do $$
declare b uuid := pg_temp.acct('w4'); ub uuid; sh uuid; r jsonb;
begin
  select user_id into ub from billing.accounts where id = b;
  sh := pg_temp.share_login();
  perform public.share_claim_live(ub, sh, 990110401, 'Gran');
  perform pg_temp.pay(b, 'home', 'month', now() - interval '1 day');
  perform pg_temp.choose(b, '{990110401}', now() - interval '1 day');
  update public.plant_users set share_missing_at = now() - interval '1 hour' where plant_id = 990110401 and user_id = ub;
  perform public.share_sync(sh, '{}');
  perform pg_temp.eq('W4 a share removed: it keeps its name', pg_temp.pp(b, now(), 990110401, 'name'), 'Gran');
  perform pg_temp.ok('W4 ... and an upgrade may keep it', billing.final_choice(b, '{990110401}', 5) = '{990110401}');
  perform pg_temp.fails('W4 a plant never chosen still needs a route',
    format('select billing.final_choice(%L, %L, 5)', b, '{990110499}'), 'not on this account');
  r := billing.set_chosen_plants(b, '{990110401}', now());
  perform pg_temp.ok('W4 saving the pick with it still chosen is allowed',
    exists (select 1 from billing.seats where account = b and plant = 990110401 and closed_at is null));
exception when others then perform pg_temp.ok('W4 runs', false, sqlerrm);
end $$;

-- W5 a cancelled plan is not upgraded: Keep first (fix 5)
do $$
declare a uuid := pg_temp.acct('w5');
begin
  perform pg_temp.member(a, 'w5', 990110501);
  perform billing.cancel(a, pg_temp.t(2));
  perform pg_temp.fails('W5 upgrade on a cancelled plan refused',
    format('select billing.upgrade(%L, %L, 0, %L, %L)', a, 'family', '{990110501}', pg_temp.t(3)), 'the plan is cancelled');
exception when others then perform pg_temp.ok('W5 runs', false, sqlerrm);
end $$;

-- W11 a booked interval switch undone: the email says undone, not booked (fix 11)
do $$
declare a uuid := pg_temp.acct('w11'); e2 bigint;
begin
  perform pg_temp.member(a, 'w11', 990111101);
  perform billing.switch_interval(a, 'year', pg_temp.t(2));
  perform billing.switch_interval(a, 'month', pg_temp.t(2) + interval '1 minute');
  select id into e2 from billing.account_events where account = a and kind = 'switch_interval' order by at desc, id desc limit 1;
  perform pg_temp.eq('W11 the switch: booked', (select key from billing.outbox where account = a and ref <> e2::text
    and key in ('change_booked', 'change_undone')), 'change_booked');
  perform pg_temp.eq('W11 its undo: undone', (select key from billing.outbox where account = a and ref = e2::text), 'change_undone');
exception when others then perform pg_temp.ok('W11 runs', false, sqlerrm);
end $$;

-- W12 new readings on a deleted plant: it has history again (fix 12)
do $$
declare a uuid := pg_temp.acct('w12'); l uuid; r jsonb;
begin
  l := pg_temp.link(a, 'w12', '{990111201}', pg_temp.t(0));
  perform pg_temp.stored(l);
  perform pg_temp.buy(a, 'home', 'month', '{990111201}', pg_temp.t(0), 'AUTH_w12');
  update billing.plants set history_purged_at = pg_temp.t(1) where id = 990111201;
  r := public.poll_commit_v2(jsonb_build_object('990111201', pg_temp.ver(990111201)), l, extract(epoch from pg_temp.t(2))::bigint,
         '[]', '[]', jsonb_build_array(jsonb_build_object('plant_id', 990111201, 'pv_w', 5)), '[]', '[]', null, null, pg_temp.t(2));
  perform pg_temp.ok('W12 written', r->>'refused' = '[]' and pg_temp.has_agg(990111201), r::text);
  perform pg_temp.ok('W12 no longer marked deleted', (select history_purged_at is null from billing.plants where id = 990111201));
exception when others then perform pg_temp.ok('W12 runs', false, sqlerrm);
end $$;

-- W13 a plan from us ended: the screens know it was not the free week (fix 13)
do $$
declare c uuid := pg_temp.acct('w13');
begin
  perform pg_temp.link(c, 'w13', '{990111301}', pg_temp.t(0));
  insert into billing.grants (account, places, reason, starts_at, ends_at) values (c, 2, 'comped', pg_temp.t(0), pg_temp.t(10));
  perform pg_temp.choose(c, '{990111301}', pg_temp.t(0));
  perform pg_temp.eq('W13 grant ended', billing.screen_state(c, pg_temp.t(12))->>'grant_ended', 'true');
  perform pg_temp.eq('W13 ... while it runs: not ended', billing.screen_state(c, pg_temp.t(5))->>'grant_ended', 'false');
exception when others then perform pg_temp.ok('W13 runs', false, sqlerrm);
end $$;

-- X1 after the switch the old plant wipe does nothing: a plant another account holds, or one
--    with a payment on its way, keeps its history through a share release and a relink (verify 3 fix 1)
do $$
declare a uuid := pg_temp.acct('x1a'); b uuid := pg_temp.acct('x1b'); c uuid := pg_temp.acct('x1c');
        ua uuid; uc uuid; sh uuid; lb uuid; inv uuid;
begin
  select user_id into ua from billing.accounts where id = a;
  select user_id into uc from billing.accounts where id = c;
  sh := pg_temp.share_login();
  -- 990120101: shared to A; B holds it through its own login and plan (no plant_users row of B's)
  perform public.share_claim_live(ua, sh, 990120101, 'Gran');
  lb := pg_temp.link(b, 'x1b', '{990120101}', now() - interval '2 days');
  perform pg_temp.stored(lb);
  perform pg_temp.pay(b, 'home', 'month', now() - interval '1 day');
  perform pg_temp.choose(b, '{990120101}', now() - interval '1 day');
  perform pg_temp.agg(990120101, now() - interval '1 hour');
  -- 990120102: shared to C, who is paying for it now (card page open)
  perform public.share_claim_live(uc, sh, 990120102, 'Aunt');
  perform pg_temp.agg(990120102, now() - interval '1 hour');
  inv := (billing.start_checkout(c, 'home', 'month', 0, '{990120102}', now())->>'invoice')::uuid;
  perform billing.begin_attempt(inv, 'card_page', now());
  perform pg_temp.ok('X1 protected by B', (billing.plant_state(990120101, now())->>'protected')::boolean);

  perform private.share_release(sh, ua);
  perform private.share_release(sh, uc);
  perform pg_temp.ok('X1 share release queues no old wipe',
    not exists (select 1 from private.plant_purge where plant_id in (990120101, 990120102)));
  -- a tombstone left from before the switch is not acted on either
  insert into private.plant_purge (plant_id) values (990120101), (990120102) on conflict do nothing;
  perform public.plant_users_upsert((select user_id from billing.accounts where id = b), lb,
    '[{"plant_id": 990120101, "plant_name": "Gran"}, {"plant_id": 990120102, "plant_name": "Aunt"}]');
  perform pg_temp.ok('X1 relink: B''s plant keeps its history', pg_temp.has_agg(990120101));
  perform pg_temp.ok('X1 relink: the plant being paid for keeps its history', pg_temp.has_agg(990120102));
  perform pg_temp.ok('X1 the old purge does nothing', private.purge_plant(990120102) is null and pg_temp.has_agg(990120102));
exception when others then perform pg_temp.ok('X1 runs', false, sqlerrm);
end $$;

-- X2 the other old delete paths stand down after the switch (sweep): the stop wipe, the
--    day-37 unpaid delete, the old run's drop; switch_on turns their jobs off
do $$
declare a uuid := pg_temp.acct('x2'); ua uuid; l uuid; r jsonb;
begin
  select user_id into ua from billing.accounts where id = a;
  l := pg_temp.link(a, 'x2', '{990120201}', now() - interval '2 days');
  perform pg_temp.stored(l);
  insert into public.plant_users (plant_id, user_id, account_id, plant_name) values (990120201, ua, l, 'X2');
  perform pg_temp.agg(990120201, now() - interval '1 hour');
  update public.plant_users set paused = true where plant_id = 990120201;
  perform pg_temp.ok('X2 stop wipe does nothing', private.plant_wipe_readings(990120201) = 0 and pg_temp.has_agg(990120201));
  r := private.unpaid_delete();
  perform pg_temp.ok('X2 unpaid delete does nothing', r = '{"live": true}' and pg_temp.has_agg(990120201), r::text);
  perform private.billing_drop_plant(ua, 990120201);
  perform pg_temp.ok('X2 old drop keeps the link and the login',
    exists (select 1 from public.plant_users where plant_id = 990120201 and user_id = ua)
    and exists (select 1 from private.sunsynk_accounts where id = l));
exception when others then perform pg_temp.ok('X2 runs', false, sqlerrm);
end $$;
do $$
declare j text;
begin
  execute 'create extension if not exists pg_cron';
  foreach j in array array['plant-purge', 'plant-wipe', 'unpaid-delete', 'free-trim', 'free-week-mail', 'offer-end-mail', 'card-expiry-mail'] loop
    perform cron.schedule(j, '0 3 * * *', 'select 1');
  end loop;
  perform billing.switch_on(pg_temp.t(0));
  perform pg_temp.eq('X2 switch_on turns the old jobs off', (select string_agg(jobname, ',') from cron.job
    where jobname in ('plant-purge', 'plant-wipe', 'unpaid-delete', 'free-trim', 'free-week-mail', 'offer-end-mail', 'card-expiry-mail')), null);
exception when others then perform pg_temp.ok('X2 jobs runs', false, sqlerrm);
end $$;

-- X3 a report on a plant the account no longer reaches (share removed) is not queued; one it
--    reaches is (verify 3 fix 3). pg_temp.x3 runs again after the drop of the old billing.
create function pg_temp.x3(p_tag text) returns text language plpgsql as $$
declare b uuid := pg_temp.acct('x3' || p_tag); ub uuid; sh uuid; p bigint := 990120300 + length(p_tag); out text := '';
begin
  select user_id into ub from billing.accounts where id = b;
  sh := pg_temp.share_login();
  perform public.share_claim_live(ub, sh, p, 'Gran');
  perform pg_temp.pay(b, 'home', 'month', now() - interval '1 day');
  perform pg_temp.choose(b, array[p], now() - interval '1 day');
  insert into public.email_queue (user_id, plant_id, kind, key) values (ub, p, 'report_week', 'report_week:x3a' || p_tag);
  if not exists (select 1 from public.email_queue where key = 'report_week:x3a' || p_tag) then out := out || 'reachable plant: no report; '; end if;
  update public.plant_users set share_missing_at = now() - interval '1 hour' where plant_id = p and user_id = ub;
  perform public.share_sync(sh, '{}');
  insert into public.email_queue (user_id, plant_id, kind, key) values (ub, p, 'report_week', 'report_week:x3b' || p_tag);
  if exists (select 1 from public.email_queue where key = 'report_week:x3b' || p_tag) then out := out || 'share removed: report queued; '; end if;
  return nullif(out, '');
end $$;
do $$
declare e text;
begin
  e := pg_temp.x3('');
  perform pg_temp.ok('X3 report only on a plant the account reaches', e is null, e);
exception when others then perform pg_temp.ok('X3 runs', false, sqlerrm);
end $$;

-- X8 the interval it already has, nothing booked: no write, no event, no email (verify 3 fix 8);
--    a repeat click on a booked switch: no version bump, no new event, the first email stays (verify 4 fix 4)
do $$
declare a uuid := pg_temp.acct('x8'); v bigint; sv bigint; n int;
begin
  perform pg_temp.member(a, 'x8', 990120801);
  select version into v from billing.accounts where id = a;
  perform billing.switch_interval(a, 'month', pg_temp.t(2));
  perform pg_temp.ok('X8 nothing changed: no event, no version bump',
    not exists (select 1 from billing.account_events where account = a and kind = 'switch_interval')
    and (select version from billing.accounts where id = a) = v);
  perform pg_temp.eq('X8 nothing changed: no email', (select string_agg(key, ',') from billing.outbox where account = a
    and key like 'change%'), null);
  perform billing.switch_interval(a, 'year', pg_temp.t(2));
  select a2.version, (pg_temp.sub(a)).version, (select count(*) from billing.outbox o where o.account = a)
    into v, sv, n from billing.accounts a2 where a2.id = a;
  perform billing.switch_interval(a, 'year', pg_temp.t(2) + interval '1 minute');
  perform pg_temp.ok('X8 repeat click: no version bump, one event',
    (select version from billing.accounts where id = a) = v and (pg_temp.sub(a)).version = sv
    and (select count(*) from billing.account_events where account = a and kind = 'switch_interval') = 1,
    format('versions %s/%s', (select version from billing.accounts where id = a), v));
  perform pg_temp.ok('X8 repeat click: the first email stays',
    (select count(*) from billing.outbox o where o.account = a) = n and n > 0
    and exists (select 1 from billing.outbox o where o.account = a and o.key = 'change_booked' and o.status = 'queued'),
    (select string_agg(key, ',') from billing.outbox where account = a));
exception when others then perform pg_temp.ok('X8 runs', false, sqlerrm);
end $$;

-- X9 a plant gone from login L1 shows under L1 (its Remove deletes it); a plant that came
--    through the share is marked shared, one from a login is not (verify 3 fix 9)
do $$
declare b uuid := pg_temp.acct('x9'); ub uuid; sh uuid; l uuid; ss jsonb;
begin
  select user_id into ub from billing.accounts where id = b;
  sh := pg_temp.share_login();
  l := pg_temp.link(b, 'x9', '{990120901,990120902}', now() - interval '2 days');
  perform public.share_claim_live(ub, sh, 990120903, 'Gran');
  perform pg_temp.pay(b, 'family', 'month', now() - interval '1 day');
  perform pg_temp.choose(b, '{990120901,990120902,990120903}', now() - interval '1 day');
  update billing.login_plants set gone_at = now() - interval '1 hour' where login = l and plant = 990120902;
  ss := billing.screen_state(b, now());
  perform pg_temp.eq('X9 gone from L1: shown under L1', (select e->>'gone_logins' from jsonb_array_elements(ss->'plants') e
    where (e->>'plant')::bigint = 990120902), jsonb_build_array(l)::text);
  perform pg_temp.eq('X9 claimed plant: shared', pg_temp.pp(b, now(), 990120903, 'name') || ' ' || (select e->>'shared'
    from jsonb_array_elements(ss->'plants') e where (e->>'plant')::bigint = 990120903), 'Gran true');
  perform pg_temp.eq('X9 a login''s plant: not shared', (select e->>'shared' from jsonb_array_elements(ss->'plants') e
    where (e->>'plant')::bigint = 990120901), 'false');
exception when others then perform pg_temp.ok('X9 runs', false, sqlerrm);
end $$;

-- Y2 a queued report is checked again when sent: a plant let go, a plant gone from its
--    login, then the plan ended: those reports are dropped, the rest go (verify 4 fix 2)
do $$
declare b uuid := pg_temp.acct('y2'); ub uuid; l uuid; got text;
begin
  select user_id into ub from billing.accounts where id = b;
  l := pg_temp.link(b, 'y2', '{990130201,990130202,990130203}', now() - interval '2 days');
  perform pg_temp.pay(b, 'family', 'month', now() - interval '1 day');
  perform pg_temp.choose(b, '{990130201,990130202,990130203}', now() - interval '1 day');
  insert into public.plant_users (plant_id, user_id, plant_name)
  select x, ub, 'Plant ' || x from unnest('{990130201,990130202,990130203}'::bigint[]) x on conflict do nothing;
  insert into public.email_queue (user_id, plant_id, kind, key) values
    (ub, 990130201, 'report_week', 'report_week:y2a'), (ub, 990130202, 'report_week', 'report_week:y2b'),
    (ub, 990130203, 'report_week', 'report_week:y2c'), (ub, null, 'report_month', 'report_month:y2');
  update billing.seats set closed_at = now(), close_reason = 'switched' where account = b and plant = 990130202;
  update billing.login_plants set gone_at = now() where login = l and plant = 990130203;
  select string_agg(c.key, ',' order by c.key) into got from public.email_claim(100000, true) c where c.user_id = ub;
  perform pg_temp.eq('Y2 let go and gone from its login: dropped when sent', got, 'report_month:y2,report_week:y2a');
  perform billing.end_sub((pg_temp.sub(b)).id, now(), 'test', now(), 'test');
  select string_agg(c.key, ',' order by c.key) into got from public.email_claim(100000, true) c where c.user_id = ub;
  perform pg_temp.eq('Y2 plan ended: no report sent', got, null);
exception when others then perform pg_temp.ok('Y2 runs', false, sqlerrm);
end $$;

-- Y3 screen_state: logins lists only the logins that list the plant now, gone_logins the
--    ones it went from; a plant gone from two logins, and one gone from a login then
--    claimed through the share; remove_login closes what the pop-up names (verify 4 fix 3)
do $$
declare b uuid := pg_temp.acct('y3'); ub uuid; sh uuid; l1 uuid; l2 uuid; ss jsonb; r jsonb;
begin
  select user_id into ub from billing.accounts where id = b;
  sh := pg_temp.share_login();
  perform pg_temp.pay(b, 'family', 'month', now() - interval '2 days');
  l1 := pg_temp.link(b, 'y3a', '{990130301,990130302}', now() - interval '2 days');
  l2 := pg_temp.link(b, 'y3b', '{990130301}', now() - interval '2 days');
  perform pg_temp.choose(b, '{990130301,990130302}', now() - interval '1 day');
  update billing.login_plants set gone_at = now() - interval '1 hour' where plant in (990130301, 990130302);
  -- the old link row a plant gone from the user's own login keeps (share_gone_at set, 0203) (verify 5 fix 9)
  insert into public.plant_users (plant_id, user_id, plant_name, share_gone_at)
  values (990130302, ub, 'Gran', now() - interval '1 hour')
  on conflict (plant_id, user_id) do update set via_share = false, share_gone_at = excluded.share_gone_at;
  perform pg_temp.eq('Y3 a plant gone from the own login can be claimed', public.share_claim_live(ub, sh, 990130302, 'Gran'), 'claimed');
  ss := billing.screen_state(b, now());
  perform pg_temp.eq('Y3 gone from two logins: no live login, both gone',
    (select (e->'logins')::text || ' ' || (e->'gone_logins')::text from jsonb_array_elements(ss->'plants') e
      where (e->>'plant')::bigint = 990130301), '[] ' || jsonb_build_array(l1, l2)::text);
  perform pg_temp.eq('Y3 gone from a login, then claimed: no live login, claimed',
    (select (e->'logins')::text || ' ' || (e->'gone_logins')::text || ' ' || (e->>'claimed') from jsonb_array_elements(ss->'plants') e
      where (e->>'plant')::bigint = 990130302), '[] ' || jsonb_build_array(l1)::text || ' true');
  begin
    r := billing.remove_login(b, l1, now());
    perform pg_temp.eq('Y3 removing L1 closes the plant gone from both, not the claimed one',
      (select string_agg(plant::text, ',' order by plant) from billing.seats where account = b and close_reason = 'login_removed'), '990130301');
    raise exception 'y3 undo';
  exception when others then if sqlerrm <> 'y3 undo' then raise; end if;
  end;
exception when others then perform pg_temp.ok('Y3 runs', false, sqlerrm);
end $$;

-- Y8 undoing a booked downgrade on Family with extra places keeps them (no extras sent: the
--    ones it has) (verify 4 fix 8)
do $$
declare a uuid := pg_temp.acct('y8');
begin
  perform pg_temp.member(a, 'y8', 990130801, 'family');
  update billing.subscriptions set extra_places = 2 where id = (pg_temp.sub(a)).id;
  perform billing.downgrade(a, 'home', null, '{}', pg_temp.t(2));
  perform pg_temp.ok('Y8 Home booked', (pg_temp.sub(a)).next_extra_places = 0 and (pg_temp.sub(a)).next_price is not null);
  perform billing.downgrade(a, 'family', null, '{}', pg_temp.t(3));
  perform pg_temp.ok('Y8 undo keeps the extra places',
    (pg_temp.sub(a)).extra_places = 2 and (pg_temp.sub(a)).next_extra_places is null and (pg_temp.sub(a)).next_price is null,
    format('extra %s, next extra %s, next price %s', (pg_temp.sub(a)).extra_places, (pg_temp.sub(a)).next_extra_places, (pg_temp.sub(a)).next_price));
exception when others then perform pg_temp.ok('Y8 runs', false, sqlerrm);
end $$;

-- Z2 an old billing email queued before the switch never goes after it; a report queued
--    before it goes without its free-week line (verify 5 fix 2)
do $$
declare b uuid := pg_temp.acct('z2'); ub uuid; sw timestamptz; got text; d jsonb;
begin
  select user_id into ub from billing.accounts where id = b;
  perform pg_temp.pay(b, 'home', 'month', now() - interval '1 day');
  select switched_at into sw from billing.switch_over;
  delete from billing.switch_over;                                         -- before the switch
  insert into public.email_queue (user_id, kind, key, data) values
    (ub, 'bill_failed', 'bill_failed:z2', '{}'), (ub, 'report_month', 'report_month:z2', '{"freeWeekEnds": true}');
  insert into billing.switch_over (switched_at) values (sw);               -- after it
  select string_agg(c.key, ',' order by c.key) into got from public.email_claim(100000, true) c where c.user_id = ub;
  perform pg_temp.eq('Z2 a failed-card email queued before the switch: skipped when sent', got, 'report_month:z2');
  select c.data into d from public.email_claim(100000, true) c where c.user_id = ub and c.key = 'report_month:z2';
  perform pg_temp.ok('Z2 a report queued before the switch: no free-week line', not (d ? 'freeWeekEnds'), coalesce(d::text, 'none'));
exception when others then perform pg_temp.ok('Z2 runs', false, sqlerrm);
end $$;

-- Z6 the screen state carries a payment on its way per plant (verify 5 fix 6)
do $$
declare a uuid := pg_temp.acct('z6'); inv uuid; ss jsonb;
begin
  perform pg_temp.link(a, 'z6', '{990130601}', now() - interval '1 hour');
  inv := (billing.start_checkout(a, 'home', 'month', 0, '{990130601}', now())->>'invoice')::uuid;
  perform billing.begin_attempt(inv, 'card_page', now());
  ss := billing.screen_state(a, now());
  perform pg_temp.eq('Z6 a plant with a payment on its way: payment_hold',
    (select e->>'payment_hold' from jsonb_array_elements(ss->'plants') e where (e->>'plant')::bigint = 990130601), 'true');
exception when others then perform pg_temp.ok('Z6 runs', false, sqlerrm);
end $$;

-- Z7 a card saved from Paystack's answer: the brand without Paystack's trailing space, so
-- "Visa •••• 4081" has one space and the Visa logo shows (seen in a test-key payment, 2026-11-23)
do $$
declare a uuid := pg_temp.acct('z7'); pm uuid;
begin
  pm := billing.save_method(a, '{"customer":{"email":"z7@state.test"},"authorization":{"authorization_code":"AUTH_z7","reusable":true,"card_type":"visa ","last4":"4081","exp_month":"12","exp_year":"2030"}}'::jsonb, now());
  perform pg_temp.eq('Z7 saved card brand trimmed', (select card_type from billing.payment_methods where id = pm), 'visa');
exception when others then perform pg_temp.ok('Z7 runs', false, sqlerrm);
end $$;

-- Z8 an ended account still holding a seat on a plant another account pays for: it no
-- longer sees that plant (its seat never closes, so it would see the payer's readings and
-- edit its settings for good); its own plant stays visible for its 30 days (final review, Neon)
do $$
declare a uuid := pg_temp.acct('z8a'); b uuid := pg_temp.acct('z8b'); ua uuid; ub uuid;
begin
  select user_id into ua from billing.accounts where id = a;
  select user_id into ub from billing.accounts where id = b;
  perform pg_temp.link(b, 'z8b', '{990140001,990140002}', now() - interval '50 days');
  perform pg_temp.pay(b, 'home', 'month', now() - interval '41 days');
  perform pg_temp.choose(b, '{990140001,990140002}', now() - interval '41 days');
  -- cancelled: the job ends the plan at its date, 10 days ago
  update billing.subscriptions set cancel_at_period_end = true where account = b;
  perform billing.run_one((select id from billing.subscriptions where account = b), now());
  perform pg_temp.link(a, 'z8a', '{990140001}', now() - interval '2 days');
  perform pg_temp.pay(a, 'home', 'month', now() - interval '1 day');
  perform pg_temp.choose(a, '{990140001}', now() - interval '1 day');
  perform pg_temp.eq('Z8 b has ended', pg_temp.st(b, now(), 'state'), 'ended');
  perform set_config('request.jwt.claims', json_build_object('sub', ub, 'role', 'authenticated')::text, true);
  perform pg_temp.ok('Z8 ended: the plant another account pays for is not seen',
    not exists (select 1 from public.my_plant_ids() x where x = 990140001));
  perform pg_temp.ok('Z8 ended: its own plant is seen while its history is kept',
    exists (select 1 from public.my_plant_ids() x where x = 990140002));
  perform set_config('request.jwt.claims', json_build_object('sub', ua, 'role', 'authenticated')::text, true);
  perform pg_temp.ok('Z8 the payer sees it', exists (select 1 from public.my_plant_ids() x where x = 990140001));
  perform set_config('request.jwt.claims', '', true);
exception when others then perform set_config('request.jwt.claims', '', true); perform pg_temp.ok('Z8 runs', false, sqlerrm);
end $$;

-- Z9 a reminder for a user with no email settings row yet: it carries an unsubscribe token,
-- so the email has its unsubscribe link and header (final review, Neon)
do $$
declare a uuid := pg_temp.acct('z9'); x jsonb;
begin
  perform pg_temp.link(a, 'z9', '{990140101}', pg_temp.t(0));
  perform pg_temp.choose(a, '{990140101}', pg_temp.t(0));
  delete from public.email_prefs where user_id = (select user_id from billing.accounts where id = a);
  perform billing.outbox_sweep(pg_temp.t(7.1));
  select e into x from jsonb_array_elements(billing.outbox_take(5000, pg_temp.t(7.1))) e
   where e->>'key' = 'trial_ended' and e->>'user' = (select user_id::text from billing.accounts where id = a);
  perform pg_temp.ok('Z9 reminder handed out', x is not null, 'none');
  perform pg_temp.ok('Z9 ... with an unsubscribe token', x->>'unsub_token' is not null, coalesce(x::text, 'none'));
exception when others then perform pg_temp.ok('Z9 runs', false, sqlerrm);
end $$;

-- Z10 the way back (DEPLOY.md, go-live review): switch_off refuses once a payment has landed
-- since the switch; before that it puts the old jobs and the old screens' calls back, stops the
-- new jobs and turns the switch off. Then on again, for the drop of the old billing after.
do $$
begin
  execute 'create extension if not exists pg_cron';
  perform cron.schedule('free-trim', '0 3 * * *', 'select 2');
  perform billing.switch_on(now());
  perform pg_temp.ok('Z10 switch_on keeps the old job it stops', exists (select 1 from billing.old_jobs
    where jobname = 'free-trim' and schedule = '0 3 * * *' and command = 'select 2')
    and not exists (select 1 from cron.job where jobname = 'free-trim'));
  perform pg_temp.fails('Z10 not before pause_payments', 'select billing.switch_off()', 'pause_payments');
  -- a try under way holds the pause's share lock from before its check, so pause_payments waits
  -- for it and switch_off then sees it (go-live review, Astra)
  perform pg_temp.ok('Z10 begin_attempt and run lock the pause before reading it', (
    select bool_and(strpos(prosrc, 'lock table billing.payments_pause in share mode') between 1
                    and strpos(prosrc, 'exists (select 1 from billing.payments_pause)'))
      from pg_proc where oid in ('billing.begin_attempt(uuid,text,timestamptz)'::regprocedure, 'billing.run(timestamptz)'::regprocedure)));
  perform billing.pause_payments();
  perform pg_temp.eq('Z10 paused: the daily run charges nothing', billing.run()->>'busy', 'true');
  perform pg_temp.fails('Z10 paused: no new try starts', $q$select billing.begin_attempt(
    (select id from billing.invoices where status = 'open' limit 1), 'card_page')$q$, 'on hold');
  -- paused: a Paystack notice and a card page's return are refused, so they come again later
  perform pg_temp.fails('Z10 paused: a Paystack notice is refused', $q$select billing.event_begin('paystack', 'charge.success', 'psh_z10', 'success', '{}')$q$, 'on hold');
  perform pg_temp.fails('Z10 paused: a payment is not applied', $q$select billing.apply_payment('psh_z10', '{"status": "success"}')$q$, 'on hold');
  -- given up (fix forward): payments start again
  perform billing.resume_payments();
  perform pg_temp.ok('Z10 resume_payments lifts the pause', not exists (select 1 from billing.payments_pause));
  perform billing.pause_payments();
  -- every earlier test's payment is after this switch time: refused
  update billing.switch_over set switched_at = now() - interval '100 years';
  perform pg_temp.fails('Z10 a payment since the switch: refused', 'select billing.switch_off()', 'fix forward');
  -- a try since the switch still open, nothing paid since: refused (go-live review, Astra)
  update billing.switch_over set switched_at = (select max(coalesce(settled_at, created_at)) from billing.payment_attempts
                                                 where status = 'success') + interval '1 second';
  insert into billing.payment_attempts (invoice, reference, provider, channel, amount_minor, currency, status, created_at)
  select id, 'psh_z10open', 'paystack', 'saved_card', amount_minor, currency, 'pending',
         (select switched_at from billing.switch_over) + interval '1 second'
    from billing.invoices where status = 'open' limit 1;
  perform pg_temp.fails('Z10 a try since the switch still open: refused', 'select billing.switch_off()', 'still open');
  delete from billing.payment_attempts where reference = 'psh_z10open';
  -- a Paystack notice received since the switch: refused (go-live review, Neon)
  insert into billing.payment_events (provider, event_type, entity_id, status, received_at)
  values ('paystack', 'refund.processed', 'z10-refund', 'processed', (select switched_at from billing.switch_over) + interval '1 second');
  perform pg_temp.fails('Z10 a Paystack notice since the switch: refused', 'select billing.switch_off()', 'fix forward');
  delete from billing.payment_events where entity_id = 'z10-refund';
  -- a refund the daily run handed out since the switch (marked sending in the same transaction,
  -- under the pause lock): refused, even before Paystack answers (go-live confirm, Astra)
  insert into billing.refunds (reference, reason, status, created_at, updated_at)
  values ('psh_z10refund', 'stale', 'sending', now() - interval '200 years', (select switched_at from billing.switch_over) + interval '1 second');
  perform pg_temp.fails('Z10 a refund handed out since the switch: refused', 'select billing.switch_off()', 'fix forward');
  delete from billing.refunds where reference = 'psh_z10refund';
  -- none since: allowed
  update billing.switch_over set switched_at = now() + interval '100 years';
  insert into billing.old_jobs (jobname, schedule, command) values ('plant-wipe', '*/7 * * * *', 'select 1')
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command;
  insert into billing.logins (account, brand, username, status, created_at)
  select id, 'sunsynk', 'z10-after-switch', 'ok', now() + interval '101 years' from billing.accounts limit 1;
  update billing.switch_over set switched_at = now() + interval '100 years';
  perform pg_temp.ok('Z10 lists a login made since the switch', billing.switch_off()->'since_switch'->'logins' @> '[{"login": "z10-after-switch"}]');
  perform pg_temp.ok('Z10 switched off', not billing.is_live());
  perform pg_temp.ok('Z10 the old job is back as it was', exists (select 1 from cron.job where jobname = 'plant-wipe'
    and schedule = '*/7 * * * *' and command = 'select 1'));
  perform pg_temp.ok('Z10 the new delete and history jobs and the daily run stopped', not exists (select 1 from cron.job
    where jobname in ('billing-delete', 'billing-history', 'billing-run')));
  perform pg_temp.ok('Z10 the old screens may call their billing changes again',
    has_function_privilege('authenticated', 'public.api_billing_change(text,text,bigint[])', 'execute')
    and has_function_privilege('authenticated', 'public.api_plant_pick(bigint[])', 'execute'));
  perform billing.switch_on(now());   -- on again for the drop of the old billing below
  perform pg_temp.ok('Z10 switched on again: payments no longer paused', not exists (select 1 from billing.payments_pause));
exception when others then perform pg_temp.ok('Z10 runs', false, sqlerrm);
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
