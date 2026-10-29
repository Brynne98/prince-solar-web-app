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
\ir ../../supabase/migrations/0110_billing.sql
\ir ../../supabase/migrations/0111_free_trim.sql
\ir ../../supabase/migrations/0112_paused_plants.sql
\ir ../../supabase/migrations/0113_plan_section.sql
\ir ../../supabase/migrations/0114_free_reports.sql
\ir ../../supabase/migrations/0116_payments.sql

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
  ('00000000-0000-0000-0000-0000000000e1', 'h@t.test'), ('00000000-0000-0000-0000-0000000000f1', 'z@t.test');

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
  -- Past the plan's one plant, a new plant links paused (0110 trigger)
  insert into public.plant_users (plant_id, user_id) values (9000099, ua);
  perform pg_temp.eq('home 2nd plant links paused', (select paused from public.plant_users where plant_id = 9000099 and user_id = ua), true);
  perform pg_temp.eq('paused plant not counted', (public.billing_may_link(ua, 'a@login.test', array[1])->>'reason'), 'upgrade_needed');
  delete from public.plant_users where plant_id = 9000099;
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
  perform public.billing_free_week_start(ur, 'Fresh@Login.test');
  perform public.billing_free_week_start(uf, 'paid@login.test');
  perform pg_temp.eq('free link records the login', (select user_id from private.free_week_logins where sunsynk_username = 'fresh@login.test'), ur);
  perform pg_temp.eq('paid link records nothing', (select count(*)::int from private.free_week_logins where sunsynk_username = 'paid@login.test'), 0);
  perform pg_temp.eq('recorded login blocks another free account',
                     public.billing_may_link('00000000-0000-0000-0000-0000000000f1', 'fresh@login.test', array[1])->>'reason', 'free_week_used');

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

  -- Paused plants (0110, 0112): Family declining the cost, not billed, not read
  insert into public.plant_users (plant_id, user_id, linked_at) values (9000025, uy, '2026-01-05');
  insert into private.inverters (sn, plant_id) values ('T-25a', 9000025), ('T-25b', 9000025);
  perform pg_temp.eq('family 5th plant active', (select paused from public.plant_users where plant_id = 9000025), false);
  perform public.billing_set_paused(uy, array[9000025::bigint], true);
  perform pg_temp.eq('paused plant not billed', public.billing_extra_inverters(uy), 1);
  perform set_config('request.jwt.claims', json_build_object('sub', uy, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('readers skip paused', (select count(*)::int from public.my_plant_ids() x where x = 9000025), 0);
  perform pg_temp.raises('my_plant refuses paused', 'select public.my_plant(9000025)', 'not linked');
  perform pg_temp.eq('switcher skips paused', (select count(*)::int from jsonb_array_elements(public.api_me()->'plants') p where (p->>'id')::bigint = 9000025), 0);
  perform set_config('request.jwt.claims', '', true);
  insert into public.email_queue (user_id, plant_id, kind, key) values (uy, 9000025, 'report_week', 'test:paused'), (uy, 9000021, 'report_week', 'test:active');
  perform pg_temp.eq('no mail for a paused plant', (select count(*)::int from public.email_queue where key = 'test:paused'), 0);
  perform pg_temp.eq('mail for an active plant', (select count(*)::int from public.email_queue where key = 'test:active'), 1);
  perform public.billing_set_paused(uy, array[9000025::bigint], false);
  perform pg_temp.eq('resumed plant billed', public.billing_extra_inverters(uy), 3);
  perform public.billing_set_paused(uy, array[9000025::bigint], true);

  -- The paywall's reader answers for the signed-in user only
  perform set_config('request.jwt.claims', json_build_object('sub', ur, 'role', 'authenticated')::text, true);
  q := public.api_billing_quote('family', 'yearly');
  perform pg_temp.eq('quote free plan',   q->>'plan', 'free');
  perform pg_temp.eq('quote free yearly', (q->>'dueNow')::int, 1799);
  perform pg_temp.eq('quote free home',   (public.api_billing_quote('home', 'monthly')->>'dueNow')::int, 99);
  perform set_config('request.jwt.claims', json_build_object('sub', uy, 'role', 'authenticated')::text, true);
  q := public.api_billing_quote('family', 'monthly', 2);
  perform pg_temp.eq('quote keeps own period', q->>'period', 'yearly');
  perform pg_temp.eq('quote yearly extras (1 now + 2 new)', (q->>'nextCharge')::int, 1799 + 3 * 588);
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.raises('quote signed out', 'select public.api_billing_quote(''family'')', 'sign in first');

  -- profiles.plan is gone; api_me reads the plan from billing
  perform pg_temp.eq('profiles.plan gone', (select count(*)::int from information_schema.columns
                       where table_schema = 'public' and table_name = 'profiles' and column_name = 'plan'), 0);
  perform set_config('request.jwt.claims', json_build_object('sub', uy, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('api_me plan', public.api_me()->>'plan', 'family');
  perform set_config('request.jwt.claims', json_build_object('sub', ur, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('api_me free', public.api_me()->>'plan', 'free');
end $$;

-- Free trim (0111): 24 hours kept once every account on the plant is Free past its week
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000061', 't1@t.test'), ('00000000-0000-0000-0000-000000000062', 't2@t.test'),
  ('00000000-0000-0000-0000-000000000063', 't3@t.test');
insert into private.free_week_logins (sunsynk_username, user_id, started_at) values
  ('t1@login.test', '00000000-0000-0000-0000-000000000061', now() - interval '10 days'),
  ('t2@login.test', '00000000-0000-0000-0000-000000000062', now() - interval '2 days'),
  ('t3@login.test', '00000000-0000-0000-0000-000000000063', now() - interval '10 days');
insert into public.plant_users (plant_id, user_id) values
  (9000061, '00000000-0000-0000-0000-000000000061'),   -- Free, week over: trimmed
  (9000062, '00000000-0000-0000-0000-000000000062'),   -- Free, still in its week
  (9000063, '00000000-0000-0000-0000-000000000063'),   -- Free, week over, but shared
  (9000063, '00000000-0000-0000-0000-0000000000a1');   -- ... with a Family account
insert into public.plant_config (plant_id, timezone, backfill_next, backfill_until, temp_next)
  values (9000061, 'Africa/Johannesburg', current_date - 50, current_date - 1, current_date - 40);
insert into public.agg_minute (plant_id, ts)
  select p, extract(epoch from now() - h * interval '1 hour')::bigint
    from unnest(array[9000061, 9000062, 9000063, 9000021]) p, unnest(array[1, 23, 25, 48, 24 * 20]) h;
insert into public.plant_energy (plant_id, bucket, period)
  select p, b, d from unnest(array[9000061, 9000062]) p,
    (values ('day', public.today_tz('Africa/Johannesburg')), ('day', public.today_tz('Africa/Johannesburg') - 1),
            ('day', public.today_tz('Africa/Johannesburg') - 5), ('month', date_trunc('month', public.today_tz('Africa/Johannesburg'))::date)) v(b, d);  -- the plant's own day, as the trim uses
insert into public.grid_off (plant_id, started_at, ended_at, last_off_at, minutes_off) values
  (9000061, now() - interval '3 days', now() - interval '3 days' + interval '1 hour', now() - interval '3 days', 60),
  (9000061, now() - interval '2 hours', null, now() - interval '1 hour', 60);

do $$
declare r jsonb;
begin
  perform pg_temp.eq('trimmed set', (select array_agg(x order by x) from public.free_trimmed_plants() x), array[9000061::bigint]);
  r := private.free_trim();
  perform pg_temp.eq('trim ran on one plant', (r->>'plants')::int, 1);
  perform pg_temp.eq('free past week keeps 24 h', (select count(*)::int from public.agg_minute where plant_id = 9000061), 2);
  perform pg_temp.eq('free in its week keeps all', (select count(*)::int from public.agg_minute where plant_id = 9000062), 5);
  perform pg_temp.eq('shared with a payer keeps all', (select count(*)::int from public.agg_minute where plant_id = 9000063), 5);
  perform pg_temp.eq('family keeps all', (select count(*)::int from public.agg_minute where plant_id = 9000021 and ts > extract(epoch from now() - interval '21 days')), 5);
  perform pg_temp.eq('day totals: today and yesterday', (select array_agg(period order by period) from public.plant_energy where plant_id = 9000061),
                     array[public.today_tz('Africa/Johannesburg') - 1, public.today_tz('Africa/Johannesburg')]);
  perform pg_temp.eq('other plant totals kept', (select count(*)::int from public.plant_energy where plant_id = 9000062), 4);
  perform pg_temp.eq('old grid-off gone, open one kept', (select count(*)::int from public.grid_off where plant_id = 9000061 and ended_at is null), 1);
  perform pg_temp.eq('grid-off count', (select count(*)::int from public.grid_off where plant_id = 9000061), 1);
  perform pg_temp.eq('import bookmarks cleared', (select row(backfill_next, backfill_until, temp_next)::text from public.plant_config where plant_id = 9000061), '(,,)');
  -- A later run deletes what has passed the cutoff since, and a row an hour behind the band is caught too
  update private.free_trim_done set at = now() - interval '6 hours' where plant_id = 9000061;
  insert into public.agg_minute (plant_id, ts) values (9000061, extract(epoch from now() - interval '28 hours')::bigint);
  perform private.free_trim();
  perform pg_temp.eq('later run trims the band', (select count(*)::int from public.agg_minute where plant_id = 9000061), 2);
  -- Upgrading leaves the trim
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
    values ('00000000-0000-0000-0000-000000000061', 'home', 'monthly', 1, current_date + 30);
  perform pg_temp.eq('upgrade leaves trim', (select count(*)::int from public.free_trimmed_plants()), 0);
  perform private.free_trim();
  perform pg_temp.eq('unmarked on leaving', (select count(*)::int from private.free_trim_done where plant_id = 9000061), 0);
end $$;
select pg_temp.eq('trim list is server only', has_function_privilege('authenticated', 'public.free_trimmed_plants()', 'execute'), false);

-- Account lists every plant with its state
insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values ('00000000-0000-0000-0000-0000000000f7', '00000000-0000-0000-0000-0000000000a1', 'y@login.test');
update public.plant_users set account_id = '00000000-0000-0000-0000-0000000000f7' where user_id = '00000000-0000-0000-0000-0000000000a1';
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000a1', 'role', 'authenticated')::text, true);
select pg_temp.eq('status lists paused plant',
  (select (p->>'paused')::boolean from public.api_link_status() s, jsonb_array_elements(s.plants) p where (p->>'plant_id')::bigint = 9000025), true);
select pg_temp.eq('status gives removal date',
  (select (p->>'remove_on') is not null from public.api_link_status() s, jsonb_array_elements(s.plants) p where (p->>'plant_id')::bigint = 9000024), true);
select set_config('request.jwt.claims', '', true);

-- Plan section (0113), as the signed-in user
do $$
declare
  uy constant uuid := '00000000-0000-0000-0000-0000000000a1';
  uh constant uuid := '00000000-0000-0000-0000-0000000000e1';
  ur constant uuid := '00000000-0000-0000-0000-0000000000b1';
  st jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uy, 'role', 'authenticated')::text, true);
  st := public.api_billing_status();
  perform pg_temp.eq('status plan', st->>'plan', 'family');
  perform pg_temp.eq('status lists booked plants', jsonb_array_length(st->'removePlants'), 2);
  st := public.api_billing_keep(9000023);
  perform pg_temp.eq('keep takes a plant off the list', jsonb_array_length(st->'removePlants'), 1);
  perform pg_temp.raises('downgrade with too many plants', 'select public.api_billing_change(''home'')', 'remove plants first');
  -- Remove login on Family: its plants are booked for the billing date, nothing goes now
  perform pg_temp.eq('remove login books it', public.api_link_remove('00000000-0000-0000-0000-0000000000f7')->>'result', 'booked');
  perform pg_temp.eq('all its plants booked', jsonb_array_length(public.api_billing_status()->'removePlants'),
                     (select count(*)::int from public.plant_users where user_id = uy));
  perform pg_temp.eq('nothing removed yet', (select count(*)::int from public.plant_users where user_id = uy) > 0, true);
  perform pg_temp.eq('login still active', (select status from private.sunsynk_accounts where id = '00000000-0000-0000-0000-0000000000f7'), 'active');
  -- With every plant booked, a downgrade to Home fits; then keeping two would break it
  perform public.api_billing_keep(9000021);
  perform pg_temp.eq('downgrade books once plants go', public.api_billing_change('home')->>'nextPlan', 'home');
  perform pg_temp.raises('keep refused when the downgrade needs it', 'select public.api_billing_keep(9000022)', 'needed for your plan change');
  perform public.api_billing_change('family');
  perform pg_temp.raises('not your login', 'select public.api_link_remove(''00000000-0000-0000-0000-000000000099'')', 'not your account');
  -- A switch booked and undone
  perform set_config('request.jwt.claims', json_build_object('sub', uh, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('home monthly now', public.api_billing_status()->>'period', 'monthly');
  perform pg_temp.eq('switch booked', public.api_billing_change('home', 'yearly')->>'nextPeriod', 'yearly');
  perform pg_temp.eq('undo with current plan', public.api_billing_change('home', 'monthly')->>'nextPeriod', null);
  perform pg_temp.eq('cancel booked', public.api_billing_change('free')->>'nextPlan', 'free');
  perform pg_temp.eq('undo cancel', public.api_billing_change('home', 'monthly')->>'nextPlan', null);
  -- Free: Remove login goes at once
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values ('00000000-0000-0000-0000-0000000000f8', ur, 'r2@login.test');
  update public.plant_users set account_id = '00000000-0000-0000-0000-0000000000f8' where user_id = ur;
  perform set_config('request.jwt.claims', json_build_object('sub', ur, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('free remove is at once', public.api_link_remove('00000000-0000-0000-0000-0000000000f8')->>'result', 'removed');
  perform pg_temp.eq('free plant gone', (select count(*)::int from public.plant_users where user_id = ur), 0);
  perform set_config('request.jwt.claims', '', true);
end $$;
select pg_temp.eq('plan calls for signed-in users', has_function_privilege('authenticated', 'public.api_billing_change(text, text)', 'execute'), true);
select pg_temp.eq('not for anon', has_function_privilege('anon', 'public.api_billing_status()', 'execute'), false);

-- Free reports (0114): none but the day-7 one; heads-up on day 5
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000071', 'd5@t.test'), ('00000000-0000-0000-0000-000000000072', 'd7@t.test');
insert into private.free_week_logins (sunsynk_username, user_id, started_at) values
  ('d5@login.test', '00000000-0000-0000-0000-000000000071', now() - interval '5 days 2 hours'),
  ('d7@login.test', '00000000-0000-0000-0000-000000000072', now() - interval '7 days 2 hours');
insert into public.plant_users (plant_id, user_id) values
  (9000071, '00000000-0000-0000-0000-000000000071'), (9000072, '00000000-0000-0000-0000-000000000072');
do $$
begin
  -- t3 (Free, week over; t1 upgraded above), t2 (Free, in its week): reports held back; Family's go
  insert into public.email_queue (user_id, plant_id, kind, key, data) values
    ('00000000-0000-0000-0000-000000000063', 9000063, 'report_week', 'test:free-report', '{}'),
    ('00000000-0000-0000-0000-000000000062', 9000062, 'report_month', 'test:free-week-report', '{}'),
    ('00000000-0000-0000-0000-000000000062', 9000062, 'grid_down', 'test:free-alert', '{}'),
    ('00000000-0000-0000-0000-0000000000a1', 9000021, 'report_week', 'test:paid-report', '{}'),
    ('00000000-0000-0000-0000-0000000000b1', null, 'report_week', 'test:old-free-report', '{}');
  perform pg_temp.eq('free past week: no report', (select count(*)::int from public.email_queue where key = 'test:free-report'), 0);
  perform pg_temp.eq('free in its week: no report', (select count(*)::int from public.email_queue where key = 'test:free-week-report'), 0);
  perform pg_temp.eq('free: alerts go', (select count(*)::int from public.email_queue where key = 'test:free-alert'), 1);
  perform pg_temp.eq('paid: reports go', (select count(*)::int from public.email_queue where key = 'test:paid-report'), 1);
  perform pg_temp.eq('free with no week on record: reports go',
    (select count(*)::int from public.email_queue where key = 'test:old-free-report'),
    (select case when exists (select 1 from private.free_week_logins where user_id = '00000000-0000-0000-0000-0000000000b1') then 0 else 1 end));
  perform private.free_week_mail();
  perform pg_temp.eq('day 5 heads-up queued', (select count(*)::int from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000071' and kind = 'free_week_soon'), 1);
  perform pg_temp.eq('day 7 report queued, past the hold-back', (select (data->>'freeWeekEnds')::boolean from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000072' and kind = 'report_week'), true);
  perform pg_temp.eq('day 7 report on the first plant', (select plant_id from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000072' and kind = 'report_week'), 9000072::bigint);
  perform pg_temp.eq('nothing for a week long over', (select count(*)::int from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000063' and kind in ('free_week_soon', 'report_week')), 0);
  perform private.free_week_mail();
  perform pg_temp.eq('each goes once', (select count(*)::int from public.email_queue
    where user_id in ('00000000-0000-0000-0000-000000000071', '00000000-0000-0000-0000-000000000072') and kind in ('free_week_soon', 'report_week')), 2);
end $$;

-- Payments (0116). s = starts on Free with two plants (second paused), then pays;
-- n = Home with no saved card; k = settles a failed renewal itself.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000091', 's@t.test'), ('00000000-0000-0000-0000-000000000092', 'n@t.test'),
  ('00000000-0000-0000-0000-000000000093', 'k@t.test');
insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values
  ('00000000-0000-0000-0000-000000000094', '00000000-0000-0000-0000-000000000091', 's@login.test');
insert into public.plant_users (plant_id, user_id, account_id, plant_name, linked_at) values
  (9000091, '00000000-0000-0000-0000-000000000091', '00000000-0000-0000-0000-000000000094', 'Home one', '2026-01-01'),
  (9000092, '00000000-0000-0000-0000-000000000091', '00000000-0000-0000-0000-000000000094', 'Home two', '2026-01-02'),
  (9000093, '00000000-0000-0000-0000-000000000092', null, 'N', '2026-01-01');
insert into private.inverters (sn, plant_id) values ('T-91', 9000091), ('T-92', 9000092);
do $$
declare
  s constant uuid := '00000000-0000-0000-0000-000000000091';
  n constant uuid := '00000000-0000-0000-0000-000000000092';
  k constant uuid := '00000000-0000-0000-0000-000000000093';
  v_card constant jsonb := '{"authorization_code": "AUTH_t1", "card_type": "visa ", "last4": "4081", "reusable": true}';
  t date := private.billing_today();
  o jsonb; ref text; runs jsonb;
begin
  perform pg_temp.eq('s starts with one plant paused', (select count(*)::int from public.plant_users where user_id = s and paused), 1);
  -- start: Free to Home, full price, period from today
  o := public.billing_charge_open(s, 'home', 'monthly');
  perform pg_temp.eq('start costs the full price', (o->>'amount')::int, 99);
  perform pg_temp.eq('no card yet', o->>'card', null::text);
  ref := o->>'reference';
  perform pg_temp.eq('pending until paid', (select plan from private.billing where user_id = s), null::text);
  perform pg_temp.raises('wrong amount refused', format('select public.billing_charge_paid(%L, null, false, 9800)', ref), 'paid 9800 cents');
  perform pg_temp.eq('paid', public.billing_charge_paid(ref, v_card, false, 9900)->>'plan', 'home');
  perform pg_temp.eq('paid twice is fine', (public.billing_charge_paid(ref, v_card)->>'again')::boolean, true);
  perform pg_temp.eq('billing date one month on', (select next_billing_date from private.billing where user_id = s),
    public.billing_step(t, 'monthly', extract(day from t)::int, 1));
  perform pg_temp.eq('card saved', (select card->>'authorization_code' from private.billing where user_id = s), 'AUTH_t1');
  perform pg_temp.eq('one upgrade email', (select count(*)::int from public.email_queue where user_id = s and kind = 'bill_upgraded'), 1);
  perform pg_temp.eq('card label', (select data->>'card' from public.email_queue where user_id = s and kind = 'bill_upgraded'), 'Visa ending 4081');
  perform pg_temp.eq('Home still covers one plant', (select count(*)::int from public.plant_users where user_id = s and paused), 1);

  -- upgrade: Home to Family resumes the paused plant, charges the saved card
  o := public.billing_charge_open(s, 'family');
  perform pg_temp.eq('upgrade uses the saved card', o->>'card', 'AUTH_t1');
  perform pg_temp.eq('upgrade on day 1 is the whole difference', (o->>'amount')::int, 80);
  perform public.billing_charge_paid(o->>'reference', v_card);
  perform pg_temp.eq('on Family', (select plan from private.billing where user_id = s), 'family');
  perform pg_temp.eq('paused plant resumed', (select count(*)::int from public.plant_users where user_id = s and paused), 0);
  perform pg_temp.eq('date unchanged', (select next_billing_date from private.billing where user_id = s),
    public.billing_step(t, 'monthly', extract(day from t)::int, 1));

  -- a failed upgrade changes nothing
  update private.billing set plan = 'home' where user_id = s;
  o := public.billing_charge_open(s, 'family');
  perform public.billing_charge_failed(o->>'reference', 'declined');
  perform pg_temp.eq('failed upgrade: plan stays', (select plan || state from private.billing where user_id = s), 'homeactive');
  update private.billing set plan = 'family' where user_id = s;

  -- renewal on the billing date, then retries on day 1, 3, 7, then Free on day 8
  update private.billing set next_billing_date = t where user_id = s;
  runs := public.billing_run(t);
  perform pg_temp.eq('renewal charged', (select count(*)::int from jsonb_array_elements(runs) x
    where x->>'card' = 'AUTH_t1' and (x->>'amount')::int = 179), 1);
  perform pg_temp.eq('date moved on', (select next_billing_date from private.billing where user_id = s), public.billing_step(t, 'monthly', extract(day from t)::int, 1));
  ref := (select x->>'reference' from jsonb_array_elements(runs) x where x->>'card' = 'AUTH_t1');
  perform pg_temp.eq('failure: next try day 1', public.billing_charge_failed(ref, 'declined')->>'nextTry', (t + 1)::text);
  perform pg_temp.eq('past due', (select state from private.billing where user_id = s), 'past_due');
  perform pg_temp.eq('nothing on day 2', (select count(*)::int from jsonb_array_elements(public.billing_run(t + 2)) x where x->>'card' = 'AUTH_t1'), 0);
  runs := public.billing_run(t + 1);
  perform pg_temp.eq('retry once a day', (select count(*)::int from jsonb_array_elements(public.billing_run(t + 1)) x where x->>'card' = 'AUTH_t1'), 0);
  ref := (select x->>'reference' from jsonb_array_elements(runs) x where x->>'card' = 'AUTH_t1');
  perform pg_temp.eq('retry same amount', (select amount from private.billing_charges where reference = ref), 179);
  update private.billing_charges set created_on = t + 1 where reference = ref;
  perform pg_temp.eq('day 1 fails: next day 3', public.billing_charge_failed(ref, 'declined')->>'nextTry', (t + 3)::text);
  ref := (select x->>'reference' from jsonb_array_elements(public.billing_run(t + 3)) x where x->>'card' = 'AUTH_t1');
  perform pg_temp.eq('day 3 fails: next day 7', public.billing_charge_failed(ref, 'declined')->>'nextTry', (t + 7)::text);
  ref := (select x->>'reference' from jsonb_array_elements(public.billing_run(t + 7)) x where x->>'card' = 'AUTH_t1');
  perform pg_temp.eq('day 7 is the last', public.billing_charge_failed(ref, 'declined')->>'nextTry', null::text);
  perform pg_temp.eq('four failure emails', (select count(*)::int from public.email_queue where user_id = s and kind = 'bill_failed'), 4);
  perform public.billing_run(t + 8);
  perform pg_temp.eq('day 8: Free', (select plan || state from private.billing where user_id = s), 'freeactive');
  perform pg_temp.eq('first plant kept', (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = s),
    '9000091:false,9000092:true');
  perform pg_temp.eq('second booked for day 38', (select remove_on from private.billing where user_id = s), t + 38);
  perform pg_temp.eq('moved-to-Free email', (select data->>'kept' || '/' || (data->'stopped'->>0) from public.email_queue where user_id = s and kind = 'bill_free'), 'Home one/Home two');
  perform public.billing_run(t + 35);
  perform pg_temp.eq('warned 3 days before', (select data->'plants'->>0 from public.email_queue where user_id = s and kind = 'bill_removal_soon'), 'Home two');
  perform public.billing_run(t + 38);
  perform pg_temp.eq('second plant deleted', (select count(*)::int from public.plant_users where user_id = s), 1);
  perform pg_temp.eq('tombstoned', (select count(*)::int from private.plant_purge where plant_id = 9000092), 1);
  perform pg_temp.eq('login kept: it still has a plant', (select count(*)::int from private.sunsynk_accounts where user_id = s), 1);
  perform pg_temp.eq('booking cleared', (select cardinality(plants_to_remove) from private.billing where user_id = s), 0);

  -- paying Family after the move to Free resumes the stopped plant and keeps it
  o := public.billing_charge_open(s, 'family', 'monthly');
  insert into public.plant_users (plant_id, user_id, account_id, plant_name, linked_at, paused) values
    (9000095, s, '00000000-0000-0000-0000-000000000094', 'Home three', '2026-01-03', true);
  update private.billing set plants_to_remove = '{9000095}', remove_on = t + 30 where user_id = s;
  perform public.billing_charge_paid(o->>'reference', v_card);
  perform pg_temp.eq('resumed after Free', (select count(*)::int from public.plant_users where user_id = s and paused), 0);
  perform pg_temp.eq('no longer booked', (select cardinality(plants_to_remove)::text || coalesce(remove_on::text, '-') from private.billing where user_id = s), '0-');

  -- a second card page paid after the first: kept for a refund, nothing applied
  update private.billing set plan = 'free', period = null, billing_day = null, next_billing_date = null where user_id = s;
  o := public.billing_charge_open(s, 'home', 'yearly');
  ref := (public.billing_charge_open(s, 'home', 'monthly'))->>'reference';
  perform public.billing_charge_paid(o->>'reference', v_card);
  perform pg_temp.eq('stale start not applied', (public.billing_charge_paid(ref, v_card)->>'applied')::boolean, false);
  perform pg_temp.eq('first one stands', (select period from private.billing where user_id = s), 'yearly');
  perform pg_temp.eq('marked for refund', (select error like 'refund:%' from private.billing_charges where reference = ref), true);
  perform pg_temp.raises('unknown period refused', format('select public.billing_charge_open(%L, %L, %L)', n, 'home', 'weekly'), 'unknown plan or period');

  -- a renewal a run opened but never reported fails on the next run
  update private.billing set next_billing_date = t where user_id = s;
  perform public.billing_run(t);
  perform public.billing_run(t + 1);
  perform pg_temp.eq('orphaned renewal failed', (select count(*)::int from private.billing_charges
    where user_id = s and kind = 'renewal' and status = 'failed' and error = 'not charged: the run stopped'), 1);
  perform pg_temp.eq('then past due from the billing date', (select past_due_since from private.billing where user_id = s), t);

  -- no saved card: the renewal fails at once
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values (n, 'home', 'monthly', 5, t);
  perform pg_temp.eq('no card: not sent to Paystack', (select count(*)::int from jsonb_array_elements(public.billing_run(t)) x
    where (x->>'amount')::int = 99 and x->>'card' is null), 0);
  perform pg_temp.eq('no card: past due', (select state from private.billing where user_id = n), 'past_due');
  perform pg_temp.raises('past due cannot upgrade', format('select public.billing_charge_open(%L, %L)', n, 'family'), 'settle the failed payment first');

  -- settle: pays the failed renewal with another card
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, past_due_since)
  values (k, 'home', 'yearly', 1, t + 300, 'past_due', t - 2);
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on)
  values ('psh_k1', k, 'renewal', 'home', 'yearly', 999, 'failed', t - 2, t - 2);
  o := public.billing_settle_open(k);
  perform pg_temp.eq('settle amount', (o->>'amount')::int, 999);
  perform public.billing_charge_paid(o->>'reference', v_card);
  perform pg_temp.eq('settled: active', (select state || coalesce(past_due_since::text, '-') from private.billing where user_id = k), 'active-');
  perform pg_temp.eq('receipt', (select count(*)::int from public.email_queue where user_id = k and kind = 'bill_paid'), 1);
  perform pg_temp.raises('nothing left to settle', format('select public.billing_settle_open(%L)', k), 'nothing to pay');

  -- a booked change is emailed; an undo is not
  perform set_config('request.jwt.claims', json_build_object('sub', k, 'role', 'authenticated')::text, true);
  perform public.api_billing_change('free');
  perform pg_temp.eq('cancel emailed', (select data->>'to' from public.email_queue where user_id = k and kind = 'bill_change'), 'free');
  perform public.api_billing_change('home', 'yearly');
  perform pg_temp.eq('undo not emailed', (select count(*)::int from public.email_queue where user_id = k and kind = 'bill_change'), 1);
  perform set_config('request.jwt.claims', '', true);

  -- yearly renewal notice 60 days before
  update private.billing set next_billing_date = t + 60 where user_id = k;
  perform public.billing_run(t);
  perform pg_temp.eq('renewal notice', (select (data->>'amount')::int from public.email_queue where user_id = k and kind = 'bill_renewal_notice'), 999);
end $$;
select pg_temp.eq('authenticated cannot mark paid', has_function_privilege('authenticated', 'public.billing_charge_paid(text, jsonb, boolean, bigint)', 'execute'), false);
select pg_temp.eq('charges closed', has_table_privilege('authenticated', 'private.billing_charges', 'select'), false);

-- Only service_role may call the rules
select pg_temp.eq('authenticated cannot', has_function_privilege('authenticated', 'public.billing_amount_due(uuid)', 'execute'), false);
select pg_temp.eq('service_role can',     has_function_privilege('service_role', 'public.billing_amount_due(uuid)', 'execute'), true);
select pg_temp.eq('billing table closed', has_table_privilege('authenticated', 'private.billing', 'select'), false);

-- Accounts from before billing (0115): Family, never billed. Run last: it comps every account.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000081', 'old@t.test');
insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values ('00000000-0000-0000-0000-000000000082', '00000000-0000-0000-0000-000000000081', 'old@login.test');
insert into public.plant_users (plant_id, user_id, account_id, paused) values
  (9000081, '00000000-0000-0000-0000-000000000081', '00000000-0000-0000-0000-000000000082', false),
  (9000082, '00000000-0000-0000-0000-000000000081', '00000000-0000-0000-0000-000000000082', true);
\ir ../../supabase/migrations/0115_existing_accounts_comped.sql
do $$
declare u constant uuid := '00000000-0000-0000-0000-000000000081';
begin
  perform pg_temp.eq('existing account on Family', (select plan || ' ' || comped from private.billing where user_id = u), 'family true');
  perform pg_temp.eq('its plants unpaused', (select count(*)::int from public.plant_users where user_id = u and paused), 0);
  perform pg_temp.eq('never billed', public.billing_amount_due(u), 0);
  perform pg_temp.eq('extra plants cost nothing', (public.billing_may_link(u, 'x@login.test', array[1, 1, 1])->>'extraInverters')::int, 0);
  perform pg_temp.raises('no plan changes', format('select public.billing_book_change(%L, %L)', u, 'home'), 'free of charge');
  perform pg_temp.raises('no renewal', format('select public.billing_renew(%L)', u), 'nothing to renew');
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('status says comped', (public.api_billing_status()->>'comped')::boolean, true);
  perform pg_temp.eq('remove login at once', public.api_link_remove('00000000-0000-0000-0000-000000000082')->>'result', 'removed');
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.eq('not trimmed', (select count(*)::int from public.free_trimmed_plants() x where x in (9000081, 9000082)), 0);
end $$;

\set QUIET off
select 'PASS' as billing_tests;
rollback;
