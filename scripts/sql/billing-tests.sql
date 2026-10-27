-- Billing rule tests (SOLAR-208 part 1). Applies the migrations the local database
-- lacks, runs every case inside one transaction, then rolls it all back.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/sql/billing-tests.sql
-- Exit code decides: any wrong case raises.
\set QUIET on
begin;
\ir ../../supabase/migrations/0104_api_export.sql
\ir ../../supabase/migrations/0105_api_export_fast.sql
\ir ../../supabase/migrations/0106_profiles_plan_guard.sql
\ir ../../supabase/migrations/0107_link_attempts.sql
\ir ../../supabase/migrations/0108_explicit_grants.sql
\ir ../../supabase/migrations/0109_waitlist_cap.sql
\ir ../../supabase/migrations/0110_billing.sql

create function pg_temp.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is distinct from want then raise exception 'FAIL %: got %, want %', label, got, want; end if;
end $$;
create function pg_temp.raises(label text, stmt text, want text) returns void language plpgsql as $$
begin
  execute stmt;
  raise exception 'FAIL %: no error, want "%"', label, want;
exception when others then
  if sqlerrm like 'FAIL %' or position(want in sqlerrm) = 0 then
    raise exception 'FAIL %: got "%", want "%"', label, sqlerrm, want;
  end if;
end $$;

-- Users: a = Home monthly, f = Family monthly 3 plants, y = Family yearly 4 plants,
-- r = free, o = other user (holds a login), j = billing day 31, h = Home yearly
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@t.test'), ('00000000-0000-0000-0000-00000000000f', 'f@t.test'),
  ('00000000-0000-0000-0000-0000000000a1', 'y@t.test'), ('00000000-0000-0000-0000-0000000000b1', 'r@t.test'),
  ('00000000-0000-0000-0000-0000000000c1', 'o@t.test'), ('00000000-0000-0000-0000-0000000000d1', 'j@t.test'),
  ('00000000-0000-0000-0000-0000000000e1', 'h@t.test');

insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values
  ('00000000-0000-0000-0000-00000000000a', 'home',   'monthly', 1,  '2026-12-01'),
  ('00000000-0000-0000-0000-00000000000f', 'family', 'monthly', 1,  '2026-12-01'),
  ('00000000-0000-0000-0000-0000000000a1', 'family', 'yearly',  1,  '2027-11-01'),
  ('00000000-0000-0000-0000-0000000000d1', 'home',   'monthly', 31, '2027-03-31'),
  ('00000000-0000-0000-0000-0000000000e1', 'home',   'yearly',  1,  '2027-11-01');

insert into public.plant_users (plant_id, user_id, linked_at) values
  (9000001, '00000000-0000-0000-0000-00000000000a', '2026-01-01'),
  (9000011, '00000000-0000-0000-0000-00000000000f', '2026-01-01'),
  (9000012, '00000000-0000-0000-0000-00000000000f', '2026-01-02'),
  (9000013, '00000000-0000-0000-0000-00000000000f', '2026-01-03'),
  (9000021, '00000000-0000-0000-0000-0000000000a1', '2026-01-01'),
  (9000022, '00000000-0000-0000-0000-0000000000a1', '2026-01-02'),
  (9000023, '00000000-0000-0000-0000-0000000000a1', '2026-01-03'),
  (9000024, '00000000-0000-0000-0000-0000000000a1', '2026-01-04'),
  (9000031, '00000000-0000-0000-0000-0000000000b1', '2026-01-01');
insert into private.inverters (sn, plant_id) values
  ('T-11', 9000011), ('T-12a', 9000012), ('T-12b', 9000012), ('T-13', 9000013),
  ('T-21', 9000021), ('T-22', 9000022), ('T-23', 9000023), ('T-24', 9000024);
insert into private.sunsynk_accounts (user_id, sunsynk_username) values
  ('00000000-0000-0000-0000-0000000000c1', 'Shared@Login.test');
insert into private.free_week_logins (sunsynk_username, user_id) values
  ('used@login.test', '00000000-0000-0000-0000-0000000000c1');

do $$
declare
  ua constant uuid := '00000000-0000-0000-0000-00000000000a';
  uf constant uuid := '00000000-0000-0000-0000-00000000000f';
  uy constant uuid := '00000000-0000-0000-0000-0000000000a1';
  ur constant uuid := '00000000-0000-0000-0000-0000000000b1';
  uo constant uuid := '00000000-0000-0000-0000-0000000000c1';
  uj constant uuid := '00000000-0000-0000-0000-0000000000d1';
  uh constant uuid := '00000000-0000-0000-0000-0000000000e1';
  q jsonb;
begin
  -- Prices
  perform pg_temp.eq('free',              public.billing_amount('free', null), 0);
  perform pg_temp.eq('home monthly',      public.billing_amount('home', 'monthly'), 99);
  perform pg_temp.eq('home yearly',       public.billing_amount('home', 'yearly'), 999);
  perform pg_temp.eq('family monthly',    public.billing_amount('family', 'monthly'), 179);
  perform pg_temp.eq('family yearly',     public.billing_amount('family', 'yearly'), 1799);
  perform pg_temp.eq('family + 2 extra',  public.billing_amount('family', 'monthly', 2), 277);
  perform pg_temp.eq('family yr + 1',     public.billing_amount('family', 'yearly', 1), 2387);

  -- Billing dates: same day each period, last day in a shorter month, then back
  perform pg_temp.eq('31 Jan -> Feb',     public.billing_step('2027-01-31', 'monthly', 31, 1), date '2027-02-28');
  perform pg_temp.eq('28 Feb -> Mar',     public.billing_step('2027-02-28', 'monthly', 31, 1), date '2027-03-31');
  perform pg_temp.eq('30 Apr -> May 31',  public.billing_step('2027-04-30', 'monthly', 31, 1), date '2027-05-31');
  perform pg_temp.eq('leap Feb',          public.billing_step('2028-01-31', 'monthly', 31, 1), date '2028-02-29');
  perform pg_temp.eq('yearly 29 Feb',     public.billing_step('2028-02-29', 'yearly', 29, 1), date '2029-02-28');
  perform pg_temp.eq('step back',         public.billing_step('2026-12-01', 'monthly', 1, -1), date '2026-11-01');

  -- Upgrade Home -> Family (R80 a month), 30-day month: Nov 2026
  perform pg_temp.eq('30d day 1',  public.billing_prorate(80, '2026-11-01', '2026-11-01', '2026-12-01'), 80);
  perform pg_temp.eq('30d mid',    public.billing_prorate(80, '2026-11-15', '2026-11-01', '2026-12-01'), 43);  -- ticket example
  perform pg_temp.eq('30d last',   public.billing_prorate(80, '2026-11-30', '2026-11-01', '2026-12-01'), 3);
  -- 28-day month: Feb 2027
  perform pg_temp.eq('28d day 1',  public.billing_prorate(80, '2027-02-01', '2027-02-01', '2027-03-01'), 80);
  perform pg_temp.eq('28d mid',    public.billing_prorate(80, '2027-02-15', '2027-02-01', '2027-03-01'), 40);
  perform pg_temp.eq('28d last',   public.billing_prorate(80, '2027-02-28', '2027-02-01', '2027-03-01'), 3);
  -- 31-day month: Jan 2027
  perform pg_temp.eq('31d day 1',  public.billing_prorate(80, '2027-01-01', '2027-01-01', '2027-02-01'), 80);
  perform pg_temp.eq('31d mid',    public.billing_prorate(80, '2027-01-15', '2027-01-01', '2027-02-01'), 44);
  perform pg_temp.eq('31d last',   public.billing_prorate(80, '2027-01-31', '2027-01-01', '2027-02-01'), 3);
  -- Yearly: Home R999 -> Family R1,799 (R800), 365-day period
  perform pg_temp.eq('yr day 1',   public.billing_prorate(800, '2026-11-01', '2026-11-01', '2027-11-01'), 800);
  perform pg_temp.eq('yr mid',     public.billing_prorate(800, '2027-05-02', '2026-11-01', '2027-11-01'), 401);
  perform pg_temp.eq('yr last',    public.billing_prorate(800, '2027-10-31', '2026-11-01', '2027-11-01'), 2);
  perform pg_temp.eq('no downgrade refund', public.billing_prorate(-80, '2026-11-15', '2026-11-01', '2026-12-01'), 0);

  -- Upgrade quotes from the user's own row: billing date stays, next charge is full
  q := public.billing_upgrade_quote(ua, 'family', 0, null, '2026-11-15');
  perform pg_temp.eq('quote home m due',  (q->>'dueNow')::int, 43);
  perform pg_temp.eq('quote home m next', (q->>'nextCharge')::int, 179);
  perform pg_temp.eq('quote home m date', (q->>'nextDate')::date, date '2026-12-01');
  q := public.billing_upgrade_quote(uh, 'family', 0, null, '2027-05-02');
  perform pg_temp.eq('quote home y due',  (q->>'dueNow')::int, 401);
  perform pg_temp.eq('quote home y next', (q->>'nextCharge')::int, 1799);
  -- billing day 31, next 31 Mar: the period started 28 Feb (31 days); 15 Mar = 16 left
  q := public.billing_upgrade_quote(uj, 'family', 0, null, '2027-03-15');
  perform pg_temp.eq('quote day-31 due',  (q->>'dueNow')::int, 41);
  -- Free -> paid: full price now, period starts today
  q := public.billing_upgrade_quote(ur, 'home', 0, 'monthly', '2026-11-15');
  perform pg_temp.eq('free -> home due',  (q->>'dueNow')::int, 99);
  perform pg_temp.eq('free -> home date', (q->>'nextDate')::date, date '2026-12-15');
  perform pg_temp.raises('family -> home is no upgrade',
    format('select public.billing_upgrade_quote(%L, %L)', uf, 'home'), 'not an upgrade');

  -- A 4th plant mid-period on Family: 2 inverters x R49 = R98, 16 of 30 days left
  perform pg_temp.eq('family 3 plants, 0 extra', public.billing_extra_inverters(uf), 0);
  q := public.billing_may_link(uf, 'new@login.test', array[2]);
  perform pg_temp.eq('4th plant ok',        (q->>'ok')::boolean, true);
  perform pg_temp.eq('4th plant inverters', (q->>'extraInverters')::int, 2);
  q := public.billing_upgrade_quote(uf, 'family', 2, null, '2026-11-15');
  perform pg_temp.eq('4th plant due now',   (q->>'dueNow')::int, 52);
  perform pg_temp.eq('4th plant next',      (q->>'nextCharge')::int, 277);
  -- Yearly Family: the 4th plant is already there, 1 inverter at R588 a year
  perform pg_temp.eq('yearly 4 plants due', public.billing_amount_due(uy), 2387);
  -- Two plants at once onto 2: the first is covered, the second is extra
  insert into public.plant_users (plant_id, user_id, linked_at) values (9000041, uo, '2026-01-01');
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
    values (uo, 'family', 'monthly', 1, '2026-12-01');
  insert into public.plant_users (plant_id, user_id, linked_at) values (9000042, uo, '2026-01-02');
  q := public.billing_may_link(uo, 'x@login.test', array[1, 3]);
  perform pg_temp.eq('3rd covered, 4th extra', (q->>'extraInverters')::int, 3);

  -- Guard a: every plant a login brings counts
  perform pg_temp.eq('free 2nd plant',    public.billing_may_link(ur, 'r@login.test', array[1])->>'reason', 'upgrade_needed');
  perform pg_temp.eq('home 2nd plant',    public.billing_may_link(ua, 'a@login.test', array[1])->>'reason', 'upgrade_needed');
  q := public.billing_may_link(ua, 'i@login.test', array[1, 1, 2]);
  perform pg_temp.eq('home + 3 plants, extra priced', (q->>'extraInverters')::int, 2);
  delete from public.plant_users where user_id = ur;
  perform pg_temp.eq('installer on free', public.billing_may_link(ur, 'i@login.test', array[1, 1, 1])->>'reason', 'upgrade_needed');
  perform pg_temp.eq('free 1st plant',    (public.billing_may_link(ur, 'r@login.test', array[1])->>'ok')::boolean, true);
  -- Guard b: one free week per login
  perform pg_temp.eq('login had free week',    public.billing_may_link(ur, 'USED@login.test', array[1])->>'reason', 'free_week_used');
  perform pg_temp.eq('login on other account', public.billing_may_link(ur, 'shared@login.test', array[1])->>'reason', 'free_week_used');
  perform pg_temp.eq('paid user, used login',  (public.billing_may_link(uf, 'used@login.test', array[1])->>'ok')::boolean, true);

  -- Downgrade at period end: plants go first, then the plan
  perform pg_temp.raises('family -> home with 3 plants',
    format('select public.billing_book_change(%L, %L)', uf, 'home'), 'remove plants first');
  perform public.billing_book_removal(uf, 9000012);
  perform public.billing_book_removal(uf, 9000013);
  perform public.billing_book_change(uf, 'home');
  perform pg_temp.eq('plan kept to period end', (select plan from private.billing where user_id = uf), 'family');
  perform pg_temp.eq('downgrade due',           public.billing_amount_due(uf), 99);
  q := public.billing_renew(uf);
  perform pg_temp.eq('renew charge',  (q->>'charge')::int, 99);
  perform pg_temp.eq('renew removes', q->'removePlants', '[9000012, 9000013]'::jsonb);
  perform pg_temp.eq('now home',      (select plan from private.billing where user_id = uf), 'home');
  perform pg_temp.eq('date kept',     (select next_billing_date from private.billing where user_id = uf), date '2027-01-01');
  perform pg_temp.raises('upgrade not booked',
    format('select public.billing_book_change(%L, %L)', uf, 'family'), 'starts at once');
  insert into public.plant_users (plant_id, user_id) values (9000031, ur);
  perform pg_temp.raises('removal on free is at once',
    format('select public.billing_book_removal(%L, 9000031)', ur), 'removal on Free');
  perform pg_temp.raises('not your plant',
    format('select public.billing_book_removal(%L, 9000041)', ur), 'not your plant');

  -- Removing an extra plant on Family: billed to period end, then dropped
  perform public.billing_book_removal(uy, 9000024);
  perform pg_temp.eq('extra still billed now', public.billing_extra_inverters(uy), 1);
  perform pg_temp.eq('extra gone next bill',   public.billing_amount_due(uy), 1799);
  perform public.billing_book_removal(uy, 9000023);
  perform pg_temp.eq('booked removals not counted: new 3rd covered, 4th extra',
                     (public.billing_may_link(uy, 'n@login.test', array[1, 2])->>'extraInverters')::int, 2);

  -- Cancel = downgrade to Free at period end
  perform public.billing_book_change(ua, 'free');
  perform pg_temp.eq('cancel kept to period end', (select plan from private.billing where user_id = ua), 'home');
  perform pg_temp.eq('cancel due', public.billing_amount_due(ua), 0);
  q := public.billing_renew(ua);
  perform pg_temp.eq('cancel charge', (q->>'charge')::int, 0);
  perform pg_temp.eq('cancel free',   (select plan || coalesce(period, '-') || coalesce(next_billing_date::text, '-')
                                         from private.billing where user_id = ua), 'free--');
  perform pg_temp.raises('renew on free', format('select public.billing_renew(%L)', ua), 'nothing to renew');

  -- Monthly -> yearly at renewal: no day maths, date stays, then a year on
  perform public.billing_book_change(uj, 'home', 'yearly');
  perform pg_temp.eq('switch kept to period end', (select period from private.billing where user_id = uj), 'monthly');
  perform pg_temp.eq('switch due', public.billing_amount_due(uj), 999);
  perform public.billing_renew(uj);
  perform pg_temp.eq('switch y date', (select period || ' ' || next_billing_date from private.billing where user_id = uj),
                     'yearly 2028-03-31');
  -- Yearly -> monthly
  perform public.billing_book_change(uh, 'home', 'monthly');
  perform pg_temp.eq('switch m due', public.billing_amount_due(uh), 99);
  perform public.billing_renew(uh);
  perform pg_temp.eq('switch m date', (select period || ' ' || next_billing_date from private.billing where user_id = uh),
                     'monthly 2027-12-01');

  -- profiles.plan is gone; api_me reads the plan from billing
  perform pg_temp.eq('profiles.plan gone', (select count(*)::int from information_schema.columns
                       where table_schema = 'public' and table_name = 'profiles' and column_name = 'plan'), 0);
  perform set_config('request.jwt.claims', json_build_object('sub', uy, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('api_me plan', public.api_me()->>'plan', 'family');
  perform set_config('request.jwt.claims', json_build_object('sub', ur, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('api_me free', public.api_me()->>'plan', 'free');
end $$;

-- Only service_role may call the rules
select pg_temp.eq('authenticated cannot', has_function_privilege('authenticated', 'public.billing_amount_due(uuid)', 'execute'), false);
select pg_temp.eq('service_role can',     has_function_privilege('service_role', 'public.billing_amount_due(uuid)', 'execute'), true);
select pg_temp.eq('billing table closed', has_table_privilege('authenticated', 'private.billing', 'select'), false);

\set QUIET off
select 'PASS' as billing_tests;
rollback;
