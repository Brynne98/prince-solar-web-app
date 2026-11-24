-- SOLAR-656 (0258): poller v3 database half. LOCAL database only; everything is rolled back.
--   /opt/homebrew/opt/libpq/bin/psql "postgresql://postgres:postgres@127.0.0.1:<db port>/postgres" -f scripts/sql/poller-v3-tests.sql
-- Exit code decides: any wrong case raises.
--   a. accounts_live = account_status on random accounts over 50 days; ends_at never late.
--   b. plants_read_now = plant_state, write_allowed_set = write_allowed,
--      reading_routes_set = reading_routes, poll_routes = poll_jobs_v2's pick.
--   c. poll_commit_batch = poll_commit_v2 once per row: same rows, side effects and answers.
--   d. a poison row rolls the whole batch back; saved login by login, only that login fails.
--   e. a free week ending by the clock: ends_at, no route after it, nothing written.
\set QUIET on
\set ON_ERROR_STOP on
\o /dev/null
begin;
select setseed(0.656);

create function pg_temp.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is distinct from want then raise exception 'FAIL %: got %, want %', label, got, want; end if;
  raise notice 'PASS  %', label;
end $$;
create function pg_temp.ok(label text, got boolean) returns void language plpgsql as $$
begin
  if got is not true then raise exception 'FAIL %', label; end if;
  raise notice 'PASS  %', label;
end $$;

-- the share login (if the database has none yet)
do $$
declare s uuid; o uuid := gen_random_uuid();
begin
  select id into s from private.sunsynk_accounts where kind = 'share';
  if s is null then
    insert into auth.users (id, email) values (o, 'v3-share@t.test');
    insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind)
    values (gen_random_uuid(), o, 'v3-share', 'active', 'share');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Random accounts: free weeks, plans in every state, cancels, unpaid renewals (some held by
-- a payment not answered), grants, too many seats, broken logins, gone plants, claims.
-- Plants come from a pool of 300, so some are seated by two accounts.
-- ---------------------------------------------------------------------------
create function pg_temp.rand_fleet(n int) returns void language plpgsql as $$
declare
  k int; j int; u uuid; a uuid; l uuid; sub uuid; inv uuid; p bigint;
  st text; t0 timestamptz := now();
  pool constant bigint := 971000000;
begin
  insert into billing.plants (id, brand, external_id)
  select pool + x, 'sunsynk', (pool + x)::text from generate_series(0, 299) x;
  insert into public.plant_config (plant_id, timezone, has_grid, batt_positive_means)
  select pool + x, case when x % 5 = 0 then 'Africa/Cairo' else 'Africa/Johannesburg' end, x % 2 = 0, case when x % 3 = 0 then 'discharging' end
    from generate_series(0, 299) x where x % 11 <> 0;
  insert into private.inverters (sn, plant_id)
  select 'RV' || (pool + x) || '-' || y, pool + x from generate_series(0, 299) x, generate_series(1, 1 + x % 3) y;
  for k in 1 .. n loop
    u := gen_random_uuid(); a := gen_random_uuid(); l := gen_random_uuid();
    insert into auth.users (id, email) values (u, 'v3-r' || k || '@t.test');
    if random() < 0.7 then
      insert into billing.accounts (id, user_id, market, trial_started_at, trial_ends_at)
      select a, u, 'ZA', s, s + interval '7 days' from (select t0 - random() * interval '20 days' as s) x;
    else
      insert into billing.accounts (id, user_id, market) values (a, u, 'ZA');
    end if;
    if random() < 0.6 then
      st := (array['active', 'active', 'past_due', 'past_due', 'ended'])[1 + floor(random() * 5)::int];
      sub := gen_random_uuid();
      insert into billing.subscriptions (id, account, plan, currency, interval, amount_minor, status, started_at, billing_day,
                                         period_start, period_end, past_due_since, cancel_at_period_end, ended_at, extra_places)
      values (sub, a, (array['home', 'family'])[1 + floor(random() * 2)::int], 'ZAR', 'month', 9900, st,
              t0 - random() * interval '40 days' + case when random() < 0.1 then interval '20 days' else interval '0' end, 1,
              t0 - interval '45 days', t0 + (random() * 40 - 10) * interval '1 day',
              case when st = 'past_due' then t0 - random() * interval '25 days' end,
              random() < 0.3,
              case when st = 'ended' then t0 + (random() * 30 - 20) * interval '1 day' end,
              floor(random() * 2)::int);
      -- an unpaid renewal held by a saved-card try with no answer yet
      if st = 'past_due' and random() < 0.4 then
        inv := gen_random_uuid();
        insert into billing.invoices (id, account, subscription, kind, status, plan, interval, amount_minor, currency, created_at)
        values (inv, a, sub, 'renewal', 'open', 'home', 'month', 9900, 'ZAR', t0 - interval '30 days');
        insert into billing.payment_attempts (invoice, reference, provider, channel, amount_minor, currency, status, created_at)
        values (inv, 'v3-ref-' || k, 'paystack', 'saved_card', 9900, 'ZAR', 'pending', t0 - interval '1 day');
      end if;
    end if;
    if random() < 0.3 then
      insert into billing.grants (account, places, reason, starts_at, ends_at)
      select a, 1 + floor(random() * 3)::int, 'test', s,
             case when random() < 0.5 then null else greatest(s + interval '1 hour', t0 + (random() * 30 - 5) * interval '1 day') end
        from (select t0 - random() * interval '10 days' as s) x;
    end if;
    insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind)
    values (l, u, 'v3-r' || k, case when random() < 0.9 then 'active' else 'needs_relink' end, 'login');
    insert into billing.logins (id, account, brand, username, status, created_at)
    values (l, a, 'sunsynk', 'v3-r' || k, case when random() < 0.85 then 'ok' else 'needs_reconnect' end,
            t0 - random() * interval '30 days');
    for j in 1 .. floor(random() * 7)::int loop
      p := pool + floor(random() * 300)::int;
      if random() < 0.85 then
        insert into billing.login_plants (login, plant, last_seen_at, gone_at)
        values (l, p, t0, case when random() < 0.1 then t0 - interval '1 day' end) on conflict do nothing;
      else
        insert into billing.plant_claims (plant, account, claimed_at) values (p, a, t0 - random() * interval '30 days')
        on conflict do nothing;
      end if;
      if random() < 0.9 and not exists (select 1 from billing.seats s where s.account = a and s.plant = p) then
        insert into billing.seats (account, plant, chosen_at, closed_at, close_reason)
        select a, p, ch, c, case when c is not null then 'switched' end
          from (select ch, case when random() < 0.1 then greatest(ch, t0) + random() * interval '10 days' end as c
                  from (select case when random() < 0.15 then t0 + random() * interval '10 days'   -- chosen later
                                    else t0 - interval '2 days' end as ch) y) x;
      end if;
    end loop;
  end loop;
end $$;
select pg_temp.rand_fleet(220);

create temp table acc as
  select a.id from billing.accounts a join auth.users u on u.id = a.user_id where u.email like 'v3-r%@t.test';
create temp table grid as
  select now() + k * interval '6 hours' + (k % 7) * interval '7 minutes' as t from generate_series(-40, 160) k
  union select now();

-- ---------------------------------------------------------------------------
-- a. accounts_live = account_status
-- ---------------------------------------------------------------------------
create temp table cmp as
  select g.t, s.account, s.live, s.must_choose, s.ends_at,
         coalesce((select st.state in ('trialing', 'active', 'past_due') from billing.account_status(s.account, g.t) st), false) as want_live,
         coalesce((select st.must_choose from billing.account_status(s.account, g.t) st), false) as want_must
    from grid g cross join lateral billing.accounts_live(array(select id from acc), g.t) s;
select pg_temp.eq('accounts_live: one row per account and time', (select count(*) from cmp),
                  (select count(*) from acc) * (select count(*) from grid));
select pg_temp.eq('accounts_live: live = account_status, every account, every time',
                  (select count(*) from cmp where live <> want_live), 0::bigint);
select pg_temp.eq('accounts_live: must_choose = account_status',
                  (select count(*) from cmp where must_choose <> want_must), 0::bigint);
select pg_temp.ok('the random fleet covers every state',
  (select count(distinct st.state) = 5 from acc cross join lateral billing.account_status(acc.id, now()) st));
select pg_temp.ok('some unpaid plans are held past their pay-by date',
  exists (select 1 from acc cross join lateral billing.account_status(acc.id, now()) st
           where st.state = 'past_due' and st.plan_ends_at <= now()));
-- ends_at is never late: from every time on the grid, an account reading then has stopped (or
-- is over its places) no earlier than ends_at, at every later time on the grid
create temp table stops as select account, t from cmp where not want_live or want_must;
create index on stops (account, t);
analyze stops;
select pg_temp.eq('ends_at never late, from every start time',
  (select count(*) from cmp n
    cross join lateral (select min(st.t) as first_stop from stops st where st.account = n.account and st.t > n.t) f
    where n.live and not n.must_choose and f.first_stop is not null
      and (n.ends_at is null or n.ends_at > f.first_stop)), 0::bigint);
-- ends_at may be early (a plan ending onto a grant or a week, a payment holding past the
-- pay-by date): the lane then waits for the next list. A plain free week ends exactly.
select pg_temp.ok('a free week alone: ends_at = its end, and reading stops then',
  (select count(*) >= 5 and bool_and(n.ends_at = a.trial_ends_at
                                     and not coalesce((select st.state in ('trialing', 'active', 'past_due')
                                                         from billing.account_status(n.account, a.trial_ends_at) st), false))
     from cmp n join billing.accounts a on a.id = n.account
    where n.t = now() and n.live
      and not exists (select 1 from billing.subscriptions s where s.account = n.account)
      and not exists (select 1 from billing.grants g where g.account = n.account)
      and not exists (select 1 from billing.seats se where se.account = n.account and se.chosen_at > now())));
select pg_temp.ok('ends_at early for under half of the accounts that end in the next 39 days',
  (select count(*) filter (where not stops) * 2 < count(*) from (
     select exists (select 1 from cmp l where l.account = n.account and l.t >= n.ends_at
                       and l.t <= n.ends_at + interval '1 day' and (not l.want_live or l.want_must)) as stops
       from cmp n where n.t = now() and n.live and not n.must_choose and n.ends_at < now() + interval '39 days') x));

-- ---------------------------------------------------------------------------
-- b. read_now, write_allowed, routes, the poll pick
-- ---------------------------------------------------------------------------
create temp table pool as select id from billing.plants where id between 971000000 and 971000299;
create temp table rn as
  select g.t, p.id,
         p.id in (select billing.plants_read_now(array(select id from pool), g.t)) as got,
         coalesce((billing.plant_state(p.id, g.t)->>'read_now')::boolean, false) as want
    from (select t from grid where t between now() - interval '1 day' and now() + interval '5 days') g cross join pool p;
select pg_temp.eq('plants_read_now = plant_state read_now (300 plants x 25 times)',
                  (select count(*) from rn where got <> want), 0::bigint);
select pg_temp.ok('some plants read now, some not', (select bool_or(got) and not bool_and(got) from rn));

create temp table vers as
  select bp.id, case when bp.id % 4 = 0 then bp.version + 1 else bp.version end as v from billing.plants bp
   where bp.id in (select id from pool);
select pg_temp.eq('write_allowed_set = write_allowed, versions right and stale, at 9 times',
  (select count(*) from (select t from grid where t between now() - interval '1 day' and now() + interval '1 day') g
    where billing.write_allowed_set((select jsonb_object_agg(id, v) from vers), g.t)
          is distinct from billing.write_allowed((select jsonb_object_agg(id, v) from vers), g.t)), 0::bigint);
select pg_temp.ok('write_allowed_set refuses stale versions',
  not exists (select 1 from unnest(billing.write_allowed_set((select jsonb_object_agg(id, v) from vers), now())) x
               where x % 4 = 0));

select pg_temp.eq('reading_routes_set = reading_routes, at 41 times',
  (select count(*) from (select t from grid where t between now() - interval '2 days' and now() + interval '8 days') g
    cross join lateral (
      (select plant, account, lane, via_share, since from billing.reading_routes_set(g.t)
       except all select * from billing.reading_routes(g.t))
      union all
      (select * from billing.reading_routes(g.t)
       except all select plant, account, lane, via_share, since from billing.reading_routes_set(g.t))) d), 0::bigint);

-- a heavy login (12 plants of 1 inverter: over 10) and a normal one, in their free week
do $$
declare u uuid; a uuid; l uuid; k int; n int;
begin
  for k in 1 .. 2 loop
    u := gen_random_uuid(); a := gen_random_uuid(); l := gen_random_uuid();
    n := case k when 1 then 12 else 3 end;
    insert into auth.users (id, email) values (u, 'v3-h' || k || '@t.test');
    insert into billing.accounts (id, user_id, market, trial_started_at, trial_ends_at)
    values (a, u, 'ZA', now() - interval '1 day', now() + interval '6 days');
    insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values (l, u, 'v3-h' || k, 'active', 'login');
    insert into billing.logins (id, account, brand, username) values (l, a, 'sunsynk', 'v3-h' || k);
    insert into billing.grants (account, places, reason, starts_at) values (a, 12, 'test', now() - interval '1 day');
    insert into billing.plants (id, brand, external_id)
    select 972000000 + k * 100 + x, 'sunsynk', (972000000 + k * 100 + x)::text from generate_series(1, n) x;
    insert into billing.login_plants (login, plant, last_seen_at) select l, 972000000 + k * 100 + x, now() from generate_series(1, n) x;
    insert into billing.seats (account, plant, chosen_at) select a, 972000000 + k * 100 + x, now() - interval '1 hour' from generate_series(1, n) x;
    insert into private.inverters (sn, plant_id) select 'HV' || (972000000 + k * 100 + x), 972000000 + k * 100 + x from generate_series(1, n) x;
  end loop;
end $$;

create temp table pr as select * from public.poll_routes(array(select generate_series(0, 59)), now());
create temp table pj as select * from public.poll_jobs_v2(0, 1, null, now());
select pg_temp.ok('the fleet has routes through logins and the share login',
  (select count(*) > 50 from pr) and exists (select 1 from pr join private.sunsynk_accounts sa on sa.id = pr.account_id where sa.kind = 'share'));
select pg_temp.eq('poll_routes over all 60 seconds = poll_jobs_v2: plant, login, version, zone, sign, grid',
  (select count(*) from (
     (select plant_id, account_id, plant_version, timezone, batt_positive_means, has_grid from pr
      except all select plant_id, account_id, plant_version, timezone, batt_positive_means, has_grid from pj)
     union all
     (select plant_id, account_id, plant_version, timezone, batt_positive_means, has_grid from pj
      except all select plant_id, account_id, plant_version, timezone, batt_positive_means, has_grid from pr)) d), 0::bigint);
select pg_temp.eq('poll_routes by second: each plant on exactly one second',
  (select count(*) from generate_series(0, 59) s cross join lateral public.poll_routes(array[s], now())),
  (select count(*) from pr));
create temp table lane_inv as
  select pr.account_id, count(i.sn) as n from pr left join private.inverters i on i.plant_id = pr.plant_id group by 1;
select pg_temp.ok('a login reading up to 10 inverters reads on the second of its id',
  not exists (select 1 from pr join private.sunsynk_accounts sa on sa.id = pr.account_id join lane_inv li using (account_id)
               where sa.kind = 'login' and li.n <= 10 and pr.read_second <> private.read_second(pr.account_id::text)));
select pg_temp.ok('the share login and a login over 10 inverters: each plant on its own second',
  not exists (select 1 from pr join private.sunsynk_accounts sa on sa.id = pr.account_id join lane_inv li using (account_id)
               where (sa.kind = 'share' or li.n > 10)
                 and pr.read_second <> private.read_second(pr.plant_id::text))
  and (select count(distinct read_second) > 3 from pr where plant_id between 972000101 and 972000112)
  and (select count(distinct read_second) = 1 from pr where plant_id between 972000201 and 972000203));
select pg_temp.ok('read seconds spread over the minute', (select count(distinct read_second) > 20 from pr));
select pg_temp.eq('ends_at = the earliest of the account''s end and the seat''s closing',
  (select count(*) from pr
    join lateral (select r.ends_at from billing.reading_routes_set(now()) r
                   where r.plant = pr.plant_id and r.lane = pr.account_id order by r.via_share, r.since limit 1) r on true
   where pr.ends_at is distinct from r.ends_at), 0::bigint);
select pg_temp.ok('a seat closing later carries its closing time',
  exists (select 1 from pr join billing.seats s on s.plant = pr.plant_id and s.closed_at > now() where pr.ends_at <= s.closed_at));

-- ---------------------------------------------------------------------------
-- c. poll_commit_batch = poll_commit_v2 called once per row, in order
-- ---------------------------------------------------------------------------
-- c1..c7: accounts; plants 973000001..
--   c1 free week, login L1: plants 1, 2 (sn S1, S2), 7 (sent with a stale version), 99 (no such plant)
--   c2 free week, login L2: plant 3, history deleted, last minute 20 min ago (gap and refill)
--   c3 week ended, login L3: plant 4 refused; its token is older than the stored one
--   c4 free week, login L4: also sees plant 1 (a duplicate read of S1, other values)
--   c5 free week, login L5: plant 5; the login breaks while reading (aborted): refused, token kept
--   c9 a login not in the batch that sees plant 1: its last_ok_at moves
do $$
declare k int; u uuid; a uuid; l uuid;
begin
  for k in 1 .. 9 loop
    continue when k in (6, 7, 8);
    u := gen_random_uuid(); a := gen_random_uuid(); l := ('00000000-0000-4000-8000-00000000000' || k)::uuid;
    insert into auth.users (id, email) values (u, 'v3-c' || k || '@t.test');
    insert into billing.accounts (id, user_id, market, trial_started_at, trial_ends_at)
    values (a, u, 'ZA', now() - case when k = 3 then interval '10 days' else interval '1 day' end,
            now() + case when k = 3 then interval '-3 days' else interval '6 days' end);
    insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind, access_token, access_expires_at)
    values (l, u, 'v3-c' || k, 'active', 'login', 'stored-' || k, 1900000000);
    insert into billing.logins (id, account, brand, username) values (l, a, 'sunsynk', 'v3-c' || k);
  end loop;
end $$;
create temp table cp (plant bigint, login int);
insert into cp values (973000001, 1), (973000002, 1), (973000007, 1), (973000003, 2), (973000004, 3),
                      (973000001, 4), (973000005, 5), (973000001, 9);
insert into billing.plants (id, brand, external_id) select distinct plant, 'sunsynk', plant::text from cp;
insert into public.plant_config (plant_id) select distinct plant from cp;
insert into billing.login_plants (login, plant, last_seen_at)
select ('00000000-0000-4000-8000-00000000000' || login)::uuid, plant, now() from cp;
insert into billing.seats (account, plant, chosen_at)
select l.account, cp.plant, now() - interval '1 hour' from cp join billing.logins l on l.username = 'v3-c' || cp.login
 where cp.login <> 9;
insert into public.plant_users (plant_id, user_id, account_id)
select 973000001, sa.user_id, sa.id from private.sunsynk_accounts sa where sa.sunsynk_username = 'v3-c9';
update billing.plants set history_purged_at = now() - interval '2 days' where id = 973000003;
update billing.plants set version = 5 where id = 973000007;
insert into public.agg_minute (plant_id, ts, pv_w, source)
values (973000003, extract(epoch from date_trunc('minute', now()))::bigint - 1200, 10, 'poller');
insert into private.meta (sn, plant_id, used_strings, string_slots, ord) values ('S1', 973000001, '{3}', 5, 7);
-- a reading of the minute before, already stored: it stays
insert into public.readings (ts, sn, plant_id, pv_w)
values (extract(epoch from date_trunc('minute', now()))::bigint - 60, 'S1', 973000001, 111);

create temp table k as select extract(epoch from date_trunc('minute', now()))::bigint as ts;
create temp table inp (n int, row jsonb);
insert into inp
select 1, jsonb_build_object(
  'account', '00000000-0000-4000-8000-000000000001',
  'versions', jsonb_build_object('973000001', (select version from billing.plants where id = 973000001),
                                 '973000002', (select version from billing.plants where id = 973000002),
                                 '973000007', 4, '973000099', 1),
  'readings', jsonb_build_array(
     jsonb_build_object('carried', false, 'ts', ts, 'sn', 'S1', 'plant_id', 973000001, 'pv_w', 100, 'grid_relay_status', 'on'),
     jsonb_build_object('carried', false, 'ts', ts, 'sn', 'S1', 'plant_id', 973000001, 'pv_w', 101),     -- same row twice: the first wins
     jsonb_build_object('carried', false, 'ts', ts, 'sn', 'S2', 'plant_id', 973000002, 'pv_w', 200),
     jsonb_build_object('carried', false, 'ts', ts, 'sn', 'S7', 'plant_id', 973000007, 'pv_w', 700),     -- stale version: dropped
     jsonb_build_object('carried', false, 'ts', ts - 60, 'sn', 'S1', 'plant_id', 973000001, 'pv_w', 999),-- stored already: kept
     jsonb_build_object('carried', false, 'ts', ts - 120, 'sn', 'S2', 'plant_id', 973000002, 'pv_w', 1)),
  'strings', jsonb_build_array(
     jsonb_build_object('ts', ts, 'sn', 'S1', 'no', 1, 'plant_id', 973000001, 'volt_v', 300, 'power_w', 50),
     jsonb_build_object('ts', ts, 'sn', 'S1', 'no', 2, 'plant_id', 973000001, 'volt_v', 0),   -- never used: dropped
     jsonb_build_object('ts', ts, 'sn', 'S1', 'no', 3, 'plant_id', 973000001, 'volt_v', 0),   -- used before: kept
     jsonb_build_object('ts', ts, 'sn', 'S1', 'no', 5, 'plant_id', 973000001, 'volt_v', 0),   -- live only in a later row: dropped here
     jsonb_build_object('ts', ts - 120, 'sn', 'S1', 'no', 6, 'plant_id', 973000001, 'volt_v', 0),
     jsonb_build_object('ts', ts, 'sn', 'S2', 'no', 1, 'plant_id', 973000002, 'volt_v', 310),
     jsonb_build_object('ts', ts, 'sn', 'S8', 'no', 1, 'plant_id', 973000001, 'volt_v', 320)),   -- S8 has no meta row yet
  'agg', jsonb_build_array(
     jsonb_build_object('plant_id', 973000001, 'pv_w', 100, 'load_w', '', 'soc', 50),
     jsonb_build_object('plant_id', 973000002, 'pv_w', 200, 'partial', true),
     jsonb_build_object('plant_id', 973000007, 'pv_w', 700)),
  'meta', jsonb_build_array(
     jsonb_build_object('sn', 'S1', 'plant_id', 973000001, 'alias', 'first', 'ord', 2, 'status', 1),
     jsonb_build_object('sn', 'S2', 'plant_id', 973000002, 'alias', 'two'),
     jsonb_build_object('sn', 'S8', 'plant_id', 973000001, 'alias', 'new'),          -- made here, after its strings
     jsonb_build_object('sn', 'S7', 'plant_id', 973000007, 'alias', 'stale')),
  'inverters', jsonb_build_array(
     jsonb_build_object('sn', 'S1', 'plant_id', 973000001, 'account_id', '00000000-0000-4000-8000-000000000001'),
     jsonb_build_object('sn', 'S2', 'plant_id', 973000002, 'account_id', '00000000-0000-4000-8000-000000000001')),
  'access', 'new-1', 'expires', 1900000500)
from k;
insert into inp
select 2, jsonb_build_object(
  'account', '00000000-0000-4000-8000-000000000002',
  'versions', jsonb_build_object('973000003', (select version from billing.plants where id = 973000003)),
  'readings', jsonb_build_array(jsonb_build_object('carried', false, 'ts', ts, 'sn', 'S3', 'plant_id', 973000003, 'pv_w', 300)),
  'agg', jsonb_build_array(jsonb_build_object('plant_id', 973000003, 'pv_w', 300)),
  'access', 'new-2', 'expires', 1900000000)            -- same expiry: the new token is saved
from k;
insert into inp
select 3, jsonb_build_object(
  'account', '00000000-0000-4000-8000-000000000003',
  'versions', jsonb_build_object('973000004', (select version from billing.plants where id = 973000004)),
  'readings', jsonb_build_array(jsonb_build_object('carried', false, 'ts', ts, 'sn', 'S4', 'plant_id', 973000004, 'pv_w', 400)),
  'agg', jsonb_build_array(jsonb_build_object('plant_id', 973000004, 'pv_w', 400)),
  'inverters', jsonb_build_array(jsonb_build_object('sn', 'S4', 'plant_id', 973000004)),
  'access', 'old-3', 'expires', 1800000000)            -- older than the stored one: not saved
from k;
insert into inp
select 4, jsonb_build_object(
  'account', '00000000-0000-4000-8000-000000000004',
  'versions', jsonb_build_object('973000001', (select version from billing.plants where id = 973000001)),
  'readings', jsonb_build_array(
     jsonb_build_object('carried', false, 'ts', ts, 'sn', 'S1', 'plant_id', 973000001, 'pv_w', 150),       -- a later row: wins
     jsonb_build_object('carried', false, 'ts', ts - 120, 'sn', 'S1', 'plant_id', 973000001, 'pv_w', 2)),
  'strings', jsonb_build_array(
     jsonb_build_object('ts', ts, 'sn', 'S1', 'no', 1, 'plant_id', 973000001, 'volt_v', 301, 'power_w', 51),
     jsonb_build_object('ts', ts, 'sn', 'S1', 'no', 4, 'plant_id', 973000001, 'volt_v', 5),
     jsonb_build_object('ts', ts, 'sn', 'S1', 'no', 5, 'plant_id', 973000001, 'volt_v', 8),
     jsonb_build_object('ts', ts - 120, 'sn', 'S1', 'no', 6, 'plant_id', 973000001, 'volt_v', 9),
     jsonb_build_object('ts', ts, 'sn', 'S8', 'no', 1, 'plant_id', 973000001, 'volt_v', 321),
     jsonb_build_object('ts', ts, 'sn', 'S8', 'no', 2, 'plant_id', 973000001, 'volt_v', 0)),
  'agg', jsonb_build_array(jsonb_build_object('plant_id', 973000001, 'pv_w', 150)),  -- the first agg wins
  'meta', jsonb_build_array(jsonb_build_object('sn', 'S1', 'plant_id', 973000001, 'alias', 'second')),
  'inverters', jsonb_build_array(
     jsonb_build_object('sn', 'S1', 'plant_id', 973000001, 'account_id', '00000000-0000-4000-8000-000000000004')),
  'access', 'new-4', 'expires', 1900000100)
from k;
insert into inp
select 5, jsonb_build_object(
  'account', '00000000-0000-4000-8000-000000000005',
  'versions', jsonb_build_object('973000005', (select version from billing.plants where id = 973000005)),
  'readings', jsonb_build_array(jsonb_build_object('carried', false, 'ts', ts, 'sn', 'S5', 'plant_id', 973000005, 'pv_w', 500)),
  'agg', jsonb_build_array(jsonb_build_object('plant_id', 973000005, 'pv_w', 500)),
  'access', 'new-5', 'expires', 1900000900)
from k;
-- a version under a key that is not the plant's own id ("0973000001"): refused, as write_allowed reads "973000001"
insert into inp
select 6, jsonb_build_object(
  'account', '00000000-0000-4000-8000-000000000001',
  'versions', jsonb_build_object('0973000001', (select version from billing.plants where id = 973000001)),
  'readings', jsonb_build_array(jsonb_build_object('carried', false, 'ts', ts, 'sn', 'S1', 'plant_id', 973000001, 'pv_w', 777)),
  'agg', jsonb_build_array(jsonb_build_object('plant_id', 973000001, 'pv_w', 777)))
from k;
-- the login breaks while the read is in flight (poll's account_mark): plant 5's version moves
select public.account_mark('00000000-0000-4000-8000-000000000005', 'needs_relink', 'test');

create temp table rows_in as select jsonb_agg(row order by n) as r from inp;

create function pg_temp.run_v2() returns jsonb language plpgsql as $$
declare e jsonb; out jsonb := '[]';
begin
  for e in select row from inp order by n loop
    out := out || jsonb_build_array(public.poll_commit_v2(
      e->'versions', (e->>'account')::uuid, (select ts from k), e->'readings', e->'strings', e->'agg',
      e->'meta', e->'inverters', e->>'access', (e->>'expires')::bigint));
  end loop;
  return out;
end $$;
create function pg_temp.run_batch() returns jsonb language sql as $$
  select jsonb_agg(b.result order by b.i) from public.poll_commit_batch((select ts from k), (select r from rows_in)) b
$$;
create function pg_temp.snap() returns jsonb language sql as $$
  select jsonb_build_object(
    'readings', (select jsonb_agg(to_jsonb(r) order by r.ts, r.sn) from public.readings r where r.plant_id between 973000000 and 973000099),
    'strings',  (select jsonb_agg(to_jsonb(s) order by s.ts, s.sn, s.no) from public.strings s where s.plant_id between 973000000 and 973000099),
    'agg',      (select jsonb_agg(to_jsonb(a) order by a.plant_id, a.ts) from public.agg_minute a where a.plant_id between 973000000 and 973000099),
    'gaps',     (select jsonb_agg(to_jsonb(g) order by g.plant_id, g.from_ts) from private.gaps g where g.plant_id between 973000000 and 973000099),
    'refill',   (select jsonb_agg(to_jsonb(q) order by q.plant_id) from private.refill_queue q where q.plant_id between 973000000 and 973000099),
    'meta',     (select jsonb_agg(to_jsonb(m) order by m.sn) from private.meta m where m.sn in ('S1', 'S2', 'S3', 'S4', 'S5', 'S7', 'S8')),
    'inverters',(select jsonb_agg(to_jsonb(i) order by i.sn) from private.inverters i where i.sn in ('S1', 'S2', 'S3', 'S4', 'S5', 'S7', 'S8')),
    'logins',   (select jsonb_agg(jsonb_build_object('u', sa.sunsynk_username, 'tok', sa.access_token, 'exp', sa.access_expires_at,
                                                     'ok', sa.last_ok_at, 'err', sa.last_error, 'st', sa.status) order by sa.sunsynk_username)
                   from private.sunsynk_accounts sa where sa.sunsynk_username like 'v3-c%'),
    'plants',   (select jsonb_agg(jsonb_build_object('id', bp.id, 'v', bp.version, 'purged', bp.history_purged_at) order by bp.id)
                   from billing.plants bp where bp.id between 973000000 and 973000099))
$$;

savepoint before_commit;
select pg_temp.run_v2() as res_v2 \gset
select pg_temp.snap() as snap_v2 \gset
rollback to savepoint before_commit;
select pg_temp.run_batch() as res_b \gset
select pg_temp.snap() as snap_b \gset

select pg_temp.eq('batch answers = poll_commit_v2 answers, row by row', :'res_b'::jsonb, :'res_v2'::jsonb);
select pg_temp.eq('same ' || k || ' after the save', (:'snap_b'::jsonb)->k, (:'snap_v2'::jsonb)->k)
  from jsonb_object_keys(:'snap_v2'::jsonb) k;
-- and what those rows are
select pg_temp.eq('S1 this minute: the later login''s row', (select pv_w from public.readings where sn = 'S1' and ts = (select ts from k)), 150::float8);
select pg_temp.eq('S1 a minute back: the stored row stays', (select pv_w from public.readings where sn = 'S1' and ts = (select ts - 60 from k)), 111::float8);
select pg_temp.eq('S1 two minutes back: the first login''s row', (select pv_w from public.readings where sn = 'S1' and ts = (select ts - 120 from k)), 2::float8);
select pg_temp.eq('plant 1 minute: the first login''s', (select pv_w from public.agg_minute where plant_id = 973000001 and ts = (select ts from k)), 100);
select pg_temp.eq('plant 2 minute partial', (select source from public.agg_minute where plant_id = 973000002 and ts = (select ts from k)), 'poller_partial');
select pg_temp.eq('strings kept: S1 inputs 1, 3, 4, 5 (2 never used)',
  (select array_agg(no order by no) from public.strings where sn = 'S1' and ts = (select ts from k)), '{1,3,4,5}'::int[]);
select pg_temp.eq('S1 input 6 two minutes back: the live row', (select volt_v from public.strings where sn = 'S1' and no = 6 and ts = (select ts - 120 from k)), 9::float8);
select pg_temp.eq('string counts: inputs dropped row by row', (select jsonb_agg(e->'strings') from jsonb_array_elements(:'res_b'::jsonb) e), '[4, 0, 0, 5, 0, 0]'::jsonb);
select pg_temp.eq('S1 input 1: the later login''s', (select volt_v from public.strings where sn = 'S1' and no = 1 and ts = (select ts from k)), 301::float8);
select pg_temp.eq('used_strings and string_slots', (select (used_strings, string_slots)::text from private.meta where sn = 'S1'), '("{1,3,4,5,6}",4)');
select pg_temp.eq('a new inverter: strings counted from the row after its meta', (select (used_strings, string_slots)::text from private.meta where sn = 'S8'), '({1},2)');
select pg_temp.eq('meta: last alias, last ord sent', (select (alias, ord, status)::text from private.meta where sn = 'S1'), '(second,2,1)');
select pg_temp.eq('inverters: the last login''s', (select account_id from private.inverters where sn = 'S1'), '00000000-0000-4000-8000-000000000004'::uuid);
select pg_temp.ok('no rows for refused plants',
  not exists (select 1 from public.readings where plant_id in (973000004, 973000005, 973000007))
  and not exists (select 1 from public.agg_minute where plant_id in (973000004, 973000005, 973000007))
  and not exists (select 1 from private.meta where sn = 'S7'));
select pg_temp.eq('refused lists', (select jsonb_agg(e->'refused') from jsonb_array_elements(:'res_b'::jsonb) e),
                  '[[973000007, 973000099], [], [973000004], [], [973000005], [973000001]]'::jsonb);
select pg_temp.eq('gap and refill for plant 3', (select (count(*), max(to_ts - from_ts))::text from private.gaps where plant_id = 973000003), '(1,1200)');
select pg_temp.ok('plant 3 queued for refill', exists (select 1 from private.refill_queue where plant_id = 973000003));
select pg_temp.eq('history deleted mark cleared', (select history_purged_at from billing.plants where id = 973000003), null::timestamptz);
select pg_temp.eq('tokens: newer saved, same expiry saved, older kept, kept for a refused login',
  (select string_agg(access_token, ',' order by sunsynk_username) from private.sunsynk_accounts where sunsynk_username like 'v3-c%'),
  'new-1,new-2,stored-3,new-4,new-5,stored-9');
select pg_temp.ok('the other login that sees plant 1 was stamped',
  (select last_ok_at = now() from private.sunsynk_accounts where sunsynk_username = 'v3-c9'));

-- ---------------------------------------------------------------------------
-- d. a poison row: the whole batch rolls back; login by login only that one fails
-- ---------------------------------------------------------------------------
rollback to savepoint before_commit;
create temp table poison as
  select (select r from rows_in) || jsonb_build_array(jsonb_build_object(
    'account', '00000000-0000-4000-8000-000000000002',
    'versions', jsonb_build_object('973000003', (select version from billing.plants where id = 973000003)),
    'readings', jsonb_build_array(jsonb_build_object('carried', false, 'ts', (select ts from k), 'sn', 'S3', 'plant_id', 973000003, 'pv_w', 'not a number')),
    'access', 'bad', 'expires', 1999999999)) as r;
do $$
begin
  begin
    perform public.poll_commit_batch((select ts from k), (select r from poison));
    raise exception 'FAIL the poison batch saved';
  exception when invalid_text_representation then null;
  end;
end $$;
select pg_temp.ok('the poison batch wrote nothing',
  not exists (select 1 from public.readings where plant_id between 973000000 and 973000099 and ts = (select ts from k))
  and not exists (select 1 from private.sunsynk_accounts where access_token in ('new-1', 'bad')));
create temp table split (i int, ok boolean);
do $$
declare e record;
begin
  for e in select x.n::int as n, x.v from jsonb_array_elements((select r from poison)) with ordinality x (v, n) loop
    begin
      perform public.poll_commit_batch((select ts from k), jsonb_build_array(e.v));
      insert into split values (e.n, true);
    exception when others then
      insert into split values (e.n, false);
    end;
  end loop;
end $$;
select pg_temp.eq('login by login: only the poison row fails', (select array_agg(i order by i) from split where not ok), '{7}'::int[]);
select pg_temp.eq('login by login: the other logins saved', (select pv_w from public.readings where sn = 'S1' and ts = (select ts from k)), 150::float8);

-- one object sending an inverter twice fails, in poll_commit_v2 and in the batch
do $$
declare r jsonb := jsonb_build_object('account', '00000000-0000-4000-8000-000000000002',
  'inverters', jsonb_build_array(jsonb_build_object('sn', 'S9', 'plant_id', 973000003), jsonb_build_object('sn', 'S9', 'plant_id', 973000003)));
begin
  begin
    perform public.poll_commit_v2('{}', '00000000-0000-4000-8000-000000000002', (select ts from k), null, null, null, null, r->'inverters', null, null);
    raise exception 'FAIL poll_commit_v2 took an inverter twice';
  exception when cardinality_violation then null;
  end;
  begin
    perform public.poll_commit_batch((select ts from k), jsonb_build_array(r));
    raise exception 'FAIL the batch took an inverter twice';
  exception when cardinality_violation then null;
  end;
  raise notice 'PASS  an inverter twice in one row fails in both';
end $$;

-- ---------------------------------------------------------------------------
-- e. a free week that ends by the clock, nothing written: ends_at stops it
-- ---------------------------------------------------------------------------
do $$
declare u uuid := gen_random_uuid(); a uuid := gen_random_uuid(); l uuid := '00000000-0000-4000-8000-000000000006';
begin
  insert into auth.users (id, email) values (u, 'v3-c6@t.test');
  insert into billing.accounts (id, user_id, market, trial_started_at, trial_ends_at)
  values (a, u, 'ZA', now() - interval '7 days' + interval '90 seconds', now() + interval '90 seconds');
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, status, kind) values (l, u, 'v3-c6', 'active', 'login');
  insert into billing.logins (id, account, brand, username) values (l, a, 'sunsynk', 'v3-c6');
  insert into billing.plants (id, brand, external_id) values (973000006, 'sunsynk', '973000006');
  insert into public.plant_config (plant_id) values (973000006);
  insert into billing.login_plants (login, plant, last_seen_at) values (l, 973000006, now());
  insert into billing.seats (account, plant, chosen_at) values (a, 973000006, now() - interval '1 hour');
end $$;
select pg_temp.eq('route carries the week''s end',
  (select ends_at from public.poll_routes(array(select generate_series(0, 59)), now()) where plant_id = 973000006),
  now() + interval '90 seconds');
select pg_temp.ok('no route after the week ends',
  not exists (select 1 from public.poll_routes(array(select generate_series(0, 59)), now() + interval '91 seconds') where plant_id = 973000006));
select pg_temp.eq('a save after the end is refused',
  (select b.result->'refused' from public.poll_commit_batch((select ts from k) + 120, jsonb_build_array(jsonb_build_object(
     'account', '00000000-0000-4000-8000-000000000006',
     'versions', jsonb_build_object('973000006', (select version from billing.plants where id = 973000006)),
     'readings', jsonb_build_array(jsonb_build_object('carried', false, 'ts', (select ts from k) + 120, 'sn', 'S6', 'plant_id', 973000006, 'pv_w', 1)),
     'agg', jsonb_build_array(jsonb_build_object('plant_id', 973000006, 'pv_w', 1)))), now() + interval '91 seconds') b),
  '[973000006]'::jsonb);
select pg_temp.ok('nothing written for it',
  not exists (select 1 from public.readings where plant_id = 973000006)
  and not exists (select 1 from public.agg_minute where plant_id = 973000006));
select pg_temp.eq('poll_commit_v2 refuses it too',
  public.poll_commit_v2(jsonb_build_object('973000006', (select version from billing.plants where id = 973000006)),
    '00000000-0000-4000-8000-000000000006', (select ts from k) + 120, null, null,
    jsonb_build_array(jsonb_build_object('plant_id', 973000006, 'pv_w', 1)), null, null, null, null,
    now() + interval '91 seconds')->'refused', '[973000006]'::jsonb);

-- ---------------------------------------------------------------------------
-- f. sunsynk_tally: the same key twice in one call is summed (0178 failed on it)
-- ---------------------------------------------------------------------------
select public.sunsynk_tally('[{"kind":"tt_dup","result":"ok","calls":2,"ms":10,"ms_max":7},
                              {"kind":"tt_dup","result":"ok","calls":3,"ms":5,"ms_max":4}]', 9, 100, 4);
select pg_temp.eq('tally: same key twice summed',
  (select (calls, ms_total, ms_max)::text from private.sunsynk_calls where kind = 'tt_dup'), '(5,15,7)');
select pg_temp.eq('tally: poll_run row', (select (calls, ms_total, plants)::text from private.sunsynk_calls
                                           where kind = 'poll_run' and result = 's9' and day = (now() at time zone 'Africa/Johannesburg')::date), '(1,100,4)');

-- ---------------------------------------------------------------------------
-- g. 0259: lane routes, cached inverters for many logins, job-check's lanes, run log
-- ---------------------------------------------------------------------------
create temp table lr as select * from public.poll_lane_routes(array(select generate_series(0, 59)), now());
select pg_temp.eq('poll_lane_routes = poll_routes, same rows',
  (select count(*) from (select plant_id, account_id, plant_version, timezone, batt_positive_means, has_grid, ends_at, read_second from lr
                         except select * from public.poll_routes(array(select generate_series(0, 59)), now())) x)
  + (select count(*) from (select * from public.poll_routes(array(select generate_series(0, 59)), now())
                           except select plant_id, account_id, plant_version, timezone, batt_positive_means, has_grid, ends_at, read_second from lr) x),
  0::bigint);
select pg_temp.ok('poll_lane_routes: the login of each route',
  not exists (select 1 from lr join private.sunsynk_accounts sa on sa.id = lr.account_id
               where (lr.user_id, lr.sunsynk_username, lr.access_token, lr.access_expires_at)
                     is distinct from (sa.user_id, sa.sunsynk_username, sa.access_token, sa.access_expires_at)));
select pg_temp.ok('poll_lane_routes: one lead per login, its lowest plant',
  not exists (select 1 from lr group by account_id
               having count(*) filter (where lead) <> 1 or min(plant_id) <> min(plant_id) filter (where lead)));
select pg_temp.eq('poll_lane_routes by seconds: each route once, lead kept',
  (select count(*) from generate_series(0, 59) s cross join lateral public.poll_lane_routes(array[s], now()) x
     join lr on lr.plant_id = x.plant_id and lr.lead = x.lead and lr.read_second = s),
  (select count(*) from lr));

-- give the random fleet's inverters a login and some readings (carried runs, upload gaps)
update private.inverters i set account_id = lp.login
  from (select distinct on (plant) plant, login from billing.login_plants order by plant, login) lp
 where lp.plant = i.plant_id and i.account_id is null and i.sn like 'RV%';
insert into public.readings (ts, sn, plant_id, device_time, carried)
select (extract(epoch from now())::bigint / 60 - m) * 60, i.sn, i.plant_id,
       to_char(now() - (m / 2) * interval '2 minutes', 'YYYY-MM-DD HH24:MI:SS'), m % 2 = 1
  from private.inverters i, generate_series(1, 6) m
 where i.sn like 'RV%' and i.plant_id % 4 = 0
on conflict do nothing;
-- inverters_cached as 0230 had it, to compare with
create function pg_temp.ic_old(p_account uuid)
returns table(sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text, gsn text, comm_type text, plant_name text, ord integer, status integer, last_reading jsonb, carried_run integer, upload_s integer)
language plpgsql
set search_path = private, pg_temp
as $$
#variable_conflict use_column
declare
  -- a variable, not now() in the query, so the planner opens 2 partitions, not all
  v_floor bigint := extract(epoch from now())::bigint - 86400;
begin
  return query
  select i.sn, i.plant_id, m.alias, m.model, m.soft_ver, m.hmi_ver,
         m.gsn, m.comm_type, m.plant_name, m.ord, m.status,
         lr.row as last_reading,
         coalesce(cr.n, 0)::integer as carried_run,
         ug.s as upload_s
    from private.inverters i
    left join private.meta m on m.sn = i.sn
    left join lateral (
      select to_jsonb(r) as row
        from public.readings r
       where r.sn = i.sn and r.ts > v_floor
       order by r.ts desc
       limit 1) lr on true
    left join lateral (
      select count(*) as n
        from public.readings r
       where r.sn = i.sn and r.ts > v_floor
         and r.ts > coalesce((select max(r2.ts) from public.readings r2
                               where r2.sn = i.sn and r2.ts > v_floor and not r2.carried), 0)) cr on true
    left join lateral (
      select min(g.gap)::integer as s
        from (select extract(epoch from (d.dt - lead(d.dt) over (order by d.dt desc))) as gap
                from (select distinct t.device_time::timestamp as dt
                        from (select r.device_time
                                from public.readings r
                               where r.sn = i.sn and r.ts > v_floor
                               order by r.ts desc
                               limit 20) t
                       where t.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                       order by 1 desc
                       limit 3) d) g
       where g.gap is not null
      having count(*) = 2) ug on true
   where i.account_id = p_account
      or i.plant_id in (select pu.plant_id from public.plant_users pu where pu.account_id = p_account)
   order by coalesce(m.ord, 9999), i.sn;
end $$;
create temp table ic_one as
  select a.id as account_id, c.* from private.sunsynk_accounts a cross join lateral pg_temp.ic_old(a.id) c;
create temp table ic_many as
  select * from public.inverters_cached_many(array(select id from private.sunsynk_accounts));
select pg_temp.ok('the fleet has cached inverters to compare', (select count(*) > 50 from ic_one));
select pg_temp.eq('inverters_cached (0259) = 0230''s, per login',
  (select count(*) from (select a.id, c.* from private.sunsynk_accounts a cross join lateral public.inverters_cached(a.id) c
                         except select * from ic_one) x), 0::bigint);
select pg_temp.eq('inverters_cached_many = 0230''s inverters_cached per login',
  (select count(*) from (select * from ic_one except select * from ic_many) x)
  + (select count(*) from (select * from ic_many except select * from ic_one) x), 0::bigint);
select pg_temp.eq('inverters_cached_many: only the plants asked',
  (select count(*) from public.inverters_cached_many(array(select id from private.sunsynk_accounts), array[971000001, 971000002]::bigint[])),
  (select count(*) from ic_one where plant_id in (971000001, 971000002)));

update private.poll_mode set mode = 'lanes', lanes = 3;
select pg_temp.eq('job-check: lanes mode lists the lanes',
  (select jsonb_agg(x->'shard' order by (x->>'shard')::int) from jsonb_array_elements(public.job_check_inputs()->'shards') x),
  '[0, 1, 2]'::jsonb);
update private.poll_mode set mode = 'edge';
select pg_temp.eq('job-check: edge mode lists the shards',
  (select count(*) from jsonb_array_elements(public.job_check_inputs()->'shards')), (select count(*) from private.poll_shards()));
delete from private.poll_mode;
select pg_temp.eq('job-check: no mode row reads as edge',
  (select count(*) from jsonb_array_elements(public.job_check_inputs()->'shards')), (select count(*) from private.poll_shards()));

insert into private.poll_runs (minute, shard, shards, scheduled_at, started_at, finished_at)
values (date_trunc('hour', now()) - interval '9 days', 0, 1, now(), now(), now());
select public.poll_run_log(jsonb_build_object('ts', extract(epoch from date_trunc('hour', now()))::bigint, 'shard', 0, 'shards', 1,
  'scheduled_ms', 0, 'started_ms', 0, 'finished_ms', 0));
select pg_temp.ok('poll_run_log on the hour keeps old rows (pruned by its own job)',
  exists (select 1 from private.poll_runs where minute = date_trunc('hour', now()) - interval '9 days'));

rollback;
\o
\echo poller-v3-tests: all passed
