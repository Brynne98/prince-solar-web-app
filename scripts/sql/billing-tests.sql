-- Billing rule tests (SOLAR-208 part 1, rules as of 0130). Needs the local database at
-- the latest migration. Runs every case inside one transaction, then rolls it all back.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/sql/billing-tests.sql
-- Exit code decides: any wrong case raises.
\set QUIET on
begin;
-- list prices: offers closed (0145); offer cases are in offer-tests.sql
update private.offers set joins_until = date '2000-01-01';

-- Wrong cases are collected and reported together at the end.
create temp table fails (n serial, what text);
create function pg_temp.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is distinct from want then insert into pg_temp.fails (what) values (format('%s: got %s, want %s', label, got, want)); end if;
end $$;
create function pg_temp.raises(label text, stmt text, want text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if position(want in sqlerrm) = 0 then
      insert into pg_temp.fails (what) values (format('%s: got "%s", want "%s"', label, sqlerrm, want));
    end if;
    return;
  end;
  insert into pg_temp.fails (what) values (format('%s: no error, want "%s"', label, want));
end $$;

-- Users: a = Home monthly, f = Family monthly 3 plants, y = Family yearly 4 plants,
-- r = free, o = other user (holds a login), j = billing day 31, h = Home yearly
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'a@t.test'), ('00000000-0000-0000-0000-00000000000f', 'f@t.test'),
  ('00000000-0000-0000-0000-0000000000a1', 'y@t.test'), ('00000000-0000-0000-0000-0000000000b1', 'r@t.test'),
  ('00000000-0000-0000-0000-0000000000c1', 'o@t.test'), ('00000000-0000-0000-0000-0000000000d1', 'j@t.test'),
  ('00000000-0000-0000-0000-0000000000e1', 'h@t.test'), ('00000000-0000-0000-0000-0000000000f1', 'z@t.test');

-- Rooms since 0156: Home 2, Family 5. a fills Home, f fills Family; y holds 1 extra plant
-- (0129, no longer sold): room for its 6.
insert into private.billing (user_id, plan, period, billing_day, next_billing_date, extra_plants) values
  ('00000000-0000-0000-0000-00000000000a', 'home',   'monthly', 1,  '2026-12-01', 0),
  ('00000000-0000-0000-0000-00000000000f', 'family', 'monthly', 1,  '2026-12-01', 0),
  ('00000000-0000-0000-0000-0000000000a1', 'family', 'yearly',  1,  '2027-11-01', 1),
  ('00000000-0000-0000-0000-0000000000d1', 'home',   'monthly', 31, '2027-03-31', 0),
  ('00000000-0000-0000-0000-0000000000e1', 'home',   'yearly',  1,  '2027-11-01', 0);

insert into public.plant_users (plant_id, user_id, linked_at) values
  (9000001, '00000000-0000-0000-0000-00000000000a', '2026-01-01'),
  (9000002, '00000000-0000-0000-0000-00000000000a', '2026-01-02'),
  (9000011, '00000000-0000-0000-0000-00000000000f', '2026-01-01'),
  (9000012, '00000000-0000-0000-0000-00000000000f', '2026-01-02'),
  (9000013, '00000000-0000-0000-0000-00000000000f', '2026-01-03'),
  (9000014, '00000000-0000-0000-0000-00000000000f', '2026-01-04'),
  (9000015, '00000000-0000-0000-0000-00000000000f', '2026-01-05'),
  (9000021, '00000000-0000-0000-0000-0000000000a1', '2026-01-01'),
  (9000022, '00000000-0000-0000-0000-0000000000a1', '2026-01-02'),
  (9000023, '00000000-0000-0000-0000-0000000000a1', '2026-01-03'),
  (9000024, '00000000-0000-0000-0000-0000000000a1', '2026-01-04'),
  (9000026, '00000000-0000-0000-0000-0000000000a1', '2026-01-05'),
  (9000027, '00000000-0000-0000-0000-0000000000a1', '2026-01-06'),
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
  perform pg_temp.eq('home yearly',       public.billing_amount('home', 'yearly'), 990);
  perform pg_temp.eq('family monthly',    public.billing_amount('family', 'monthly'), 199);
  perform pg_temp.eq('family yearly',     public.billing_amount('family', 'yearly'), 1990);
  perform pg_temp.eq('family + 2 extra',  public.billing_amount('family', 'monthly', 2), 297);
  perform pg_temp.eq('family yr + 1',     public.billing_amount('family', 'yearly', 1), 2578);

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
  perform pg_temp.eq('quote home m due',  (q->>'dueNow')::int, 53);
  perform pg_temp.eq('quote home m next', (q->>'nextCharge')::int, 199);
  perform pg_temp.eq('quote home m date', (q->>'nextDate')::date, date '2026-12-01');
  q := public.billing_upgrade_quote(uh, 'family', 0, null, '2027-05-02');
  perform pg_temp.eq('quote home y due',  (q->>'dueNow')::int, 501);
  perform pg_temp.eq('quote home y next', (q->>'nextCharge')::int, 1990);
  -- billing day 31, next 31 Mar: the period started 28 Feb (31 days); 15 Mar = 16 left
  q := public.billing_upgrade_quote(uj, 'family', 0, null, '2027-03-15');
  perform pg_temp.eq('quote day-31 due',  (q->>'dueNow')::int, 52);
  -- Free -> paid: full price now, period starts today
  q := public.billing_upgrade_quote(ur, 'home', 0, 'monthly', '2026-11-15');
  perform pg_temp.eq('free -> home due',  (q->>'dueNow')::int, 99);
  perform pg_temp.eq('free -> home date', (q->>'nextDate')::date, date '2026-12-15');
  perform pg_temp.raises('family -> home is no upgrade',
    format('select public.billing_upgrade_quote(%L, %L)', uf, 'home'), 'not an upgrade');

  -- Room (0156): Free 1, Home 2, Family 5 + any extra plants held (0129, no longer sold)
  perform pg_temp.eq('room free',           public.billing_room('free'), 1);
  perform pg_temp.eq('room home',           public.billing_room('home'), 2);
  perform pg_temp.eq('room family + 2',     public.billing_room('family', 2), 7);
  -- 1 extra plant mid-period on Family: R49, 16 of 30 days left
  perform pg_temp.eq('6th plant ok',        (public.billing_may_link(uf, 'new@login.test', array[2])->>'ok')::boolean, false);
  q := public.billing_upgrade_quote(uf, 'family', 1, null, '2026-11-15');
  perform pg_temp.eq('6th plant due now',   (q->>'dueNow')::int, public.billing_prorate(49, '2026-11-15', '2026-11-01', '2026-12-01'));
  perform pg_temp.eq('6th plant next',      (q->>'nextCharge')::int, 248);
  -- Yearly Family with 1 extra plant: R588 a year
  perform pg_temp.eq('yearly 6 plants due', public.billing_amount_due(uy), 2578);
  insert into public.plant_users (plant_id, user_id, linked_at) values (9000041, uo, '2026-01-01');
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
    values (uo, 'family', 'monthly', 1, '2026-12-01');

  -- Guard a: every plant a login brings counts
  -- Past the plan's room, a new plant links paused (0110 trigger)
  insert into public.plant_users (plant_id, user_id) values (9000099, ua);
  perform pg_temp.eq('home 3rd plant links paused', (select paused from public.plant_users where plant_id = 9000099 and user_id = ua), true);
  perform pg_temp.eq('paused plant not counted', (public.billing_may_link(ua, 'a@login.test', array[1])->>'reason'), 'upgrade_needed');
  delete from public.plant_users where plant_id = 9000099;
  perform pg_temp.eq('free 2nd plant',    public.billing_may_link(ur, 'r@login.test', array[1])->>'reason', 'upgrade_needed');
  perform pg_temp.eq('home 3rd plant',    public.billing_may_link(ua, 'a@login.test', array[1])->>'reason', 'upgrade_needed');
  delete from public.plant_users where user_id = ur;
  perform pg_temp.eq('installer on free', public.billing_may_link(ur, 'i@login.test', array[1, 1, 1])->>'reason', 'upgrade_needed');
  perform pg_temp.eq('free 1st plant',    (public.billing_may_link(ur, 'r@login.test', array[1])->>'ok')::boolean, true);
  -- The free week: one per account, started by its first link on any plan (0121, 0127)
  perform public.billing_free_week_start(ur, 'Fresh@Login.test');
  perform public.billing_free_week_start(uf, 'paid@login.test');
  perform pg_temp.eq('free link records the login', (select user_id from private.free_week_logins where sunsynk_username = 'fresh@login.test'), ur);
  perform pg_temp.eq('paid link records it too', (select count(*)::int from private.free_week_logins where sunsynk_username = 'paid@login.test'), 1);

  -- Downgrade at period end. With 5 plants it books; the 3 not picked stop on the date (0136).
  perform public.billing_book_change(uf, 'home');
  perform pg_temp.eq('family -> home with 5 plants books', (select cardinality(private.billing_drops(b)) from private.billing b where user_id = uf), 3);
  perform public.billing_book_removal(uf, 9000012);
  perform public.billing_book_removal(uf, 9000013);
  perform public.billing_book_removal(uf, 9000014);
  perform public.billing_book_change(uf, 'home');
  perform pg_temp.eq('plan kept to period end', (select plan from private.billing where user_id = uf), 'family');
  perform pg_temp.eq('downgrade due',           public.billing_amount_due(uf), 99);
  q := public.billing_renew(uf);
  perform pg_temp.eq('renew charge',  (q->>'charge')::int, 99);
  perform pg_temp.eq('renew removes', q->'removePlants', '[9000012, 9000013, 9000014]'::jsonb);
  perform pg_temp.eq('now home',      (select plan from private.billing where user_id = uf), 'home');
  perform pg_temp.eq('date kept',     (select next_billing_date from private.billing where user_id = uf), date '2027-01-01');
  perform pg_temp.raises('upgrade not booked',
    format('select public.billing_book_change(%L, %L)', uf, 'family'), 'starts at once');
  insert into public.plant_users (plant_id, user_id) values (9000031, ur);
  perform pg_temp.raises('removal on free is at once',
    format('select public.billing_book_removal(%L, 9000031)', ur), 'removal on Free');
  perform pg_temp.raises('not your plant',
    format('select public.billing_book_removal(%L, 9000041)', ur), 'not your plant');

  -- Removing a plant on Family: the room bought stays billed until it is lowered (0129)
  perform public.billing_book_removal(uy, 9000024);
  perform pg_temp.eq('room still billed', public.billing_amount_due(uy), 2578);
  perform public.billing_book_removal(uy, 9000023);

  -- Cancel = downgrade to Free at period end
  perform public.billing_book_change(ua, 'free');
  perform pg_temp.eq('cancel kept to period end', (select plan from private.billing where user_id = ua), 'home');
  perform pg_temp.eq('cancel due', public.billing_amount_due(ua), 0);
  q := public.billing_renew(ua);
  perform pg_temp.eq('cancel charge', (q->>'charge')::int, 0);
  perform pg_temp.eq('cancel free',   (select plan || coalesce(period, '-') || coalesce(next_billing_date::text, '-')
                                         from private.billing where user_id = ua), 'free--');
  perform pg_temp.raises('renew on free', format('select public.billing_renew(%L)', ua), 'nothing to renew');

  -- Monthly -> yearly is paid now, the year starts on the billing date (0138): no day maths,
  -- date stays, then a year on with no second charge
  perform pg_temp.raises('switch not booked', format('select public.billing_book_change(%L, ''home'', ''yearly'')', uj), 'paid now');
  q := public.billing_upgrade_quote(uj, 'home', 0, 'yearly');
  perform pg_temp.eq('switch quote', q->>'dueNow' || ' ' || (q->>'startsOn') || ' ' || (q->>'nextDate'), '990 2027-03-31 2028-03-31');
  q := public.billing_charge_open(uj, 'home', 'yearly');
  perform pg_temp.eq('switch charge', (select kind || ' ' || period || ' ' || amount || ' ' || billing_date
                                         from private.billing_charges where reference = q->>'reference'), 'switch yearly 990 2027-03-31');
  -- a double tap opens two; the second paid goes back
  perform set_config('t.switch2', public.billing_charge_open(uj, 'home', 'yearly')->>'reference', true);
  perform public.billing_charge_paid(q->>'reference');
  perform pg_temp.eq('second switch refunded', public.billing_charge_paid(current_setting('t.switch2'))->>'refund', 'true');
  perform pg_temp.eq('switch kept to period end', (select period || ' ' || next_period || ' ' || prepaid_on
                                                     from private.billing where user_id = uj), 'monthly yearly 2027-03-31');
  perform pg_temp.eq('switch receipt', (select data->>'amount' || ' ' || (data->>'startsOn') || ' ' || (data->>'nextDate')
                                          from public.email_queue where user_id = uj and kind = 'bill_switched'), '990 2027-03-31 2028-03-31');
  -- no undo, no other change, no second switch until the year starts
  -- the plan as it is books nothing: the switch stays (0176)
  perform public.billing_book_change(uj, 'home', 'monthly');
  perform pg_temp.eq('switch no undo', (select coalesce(next_plan, '-') || ' ' || next_period || ' ' || prepaid_on from private.billing where user_id = uj),
                     '- yearly 2027-03-31');
  -- a cancel is allowed and books the end of the paid year (0175); undone after
  begin
    perform public.billing_book_change(uj, 'free');
    perform pg_temp.eq('switch cancel keeps the switch', (select next_plan || ' ' || next_period || ' ' || prepaid_on from private.billing where user_id = uj),
                       'free yearly 2027-03-31');
    perform pg_temp.raises('switch cancel: no downgrade', format('select public.billing_book_change(%L, ''family'')', uj), 'year is paid');
    -- Keep goes back to the paid switch (0176), then the cancel again
    perform public.billing_book_change(uj, 'home', 'monthly');
    perform pg_temp.eq('switch cancel undone', (select coalesce(next_plan, '-') || ' ' || next_period || ' ' || prepaid_on || ' ' || cardinality(next_keep)
                                                  from private.billing where user_id = uj), '- yearly 2027-03-31 0');
    perform public.billing_book_change(uj, 'free');
    perform pg_temp.eq('switch cancel: the year starts', (public.billing_renew(uj)->>'charge')::int, 0);
    perform pg_temp.eq('switch cancel: ends a year on', (select period || ' ' || next_billing_date || ' ' || next_plan || ' ' || coalesce(prepaid_on::text, '-')
                                                          from private.billing where user_id = uj), 'yearly 2028-03-31 free -');
    raise exception 'undo' using errcode = 'T0001';
  exception when sqlstate 'T0001' then null;
  end;
  perform pg_temp.raises('switch no upgrade', format('select public.billing_charge_open(%L, ''family'')', uj), 'year is paid');
  perform pg_temp.raises('switch once', format('select public.billing_charge_open(%L, ''home'', ''yearly'')', uj), 'year is paid');
  -- a move to Free (a lost dispute left unpaid) ends the paid year; undone after
  begin
    perform private.billing_to_free(uj, '2026-11-20');
    perform pg_temp.eq('free ends the paid year', (select plan || ' ' || coalesce(prepaid_on::text, '-') from private.billing where user_id = uj), 'free -');
    raise exception 'undo' using errcode = 'T0001';
  exception when sqlstate 'T0001' then null;
  end;
  q := public.billing_renew(uj);
  perform pg_temp.eq('switch renewal free', (q->>'charge')::int, 0);
  perform pg_temp.eq('switch y date', (select period || ' ' || next_billing_date || ' ' || coalesce(prepaid_on::text, '-')
                                         from private.billing where user_id = uj), 'yearly 2028-03-31 -');
  perform pg_temp.eq('switch y due', public.billing_amount_due(uj), 990);
  -- Yearly -> monthly
  perform public.billing_book_change(uh, 'home', 'monthly');
  perform pg_temp.eq('switch m due', public.billing_amount_due(uh), 99);
  perform public.billing_renew(uh);
  perform pg_temp.eq('switch m date', (select period || ' ' || next_billing_date from private.billing where user_id = uh),
                     'monthly 2027-12-01');

  -- Stopped plants (0110, 0112, 0129): past the room a plant links stopped, not read
  insert into public.plant_users (plant_id, user_id, linked_at) values (9000025, uy, '2026-01-05');
  insert into private.inverters (sn, plant_id) values ('T-25a', 9000025), ('T-25b', 9000025);
  perform pg_temp.eq('family 5th plant links stopped', (select paused from public.plant_users where plant_id = 9000025), true);
  perform set_config('request.jwt.claims', json_build_object('sub', uy, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('readers skip paused', (select count(*)::int from public.my_plant_ids() x where x = 9000025), 0);
  perform pg_temp.raises('my_plant refuses paused', 'select public.my_plant(9000025)', 'not linked');
  perform pg_temp.eq('switcher skips paused', (select count(*)::int from jsonb_array_elements(public.api_me()->'plants') p where (p->>'id')::bigint = 9000025), 0);
  perform set_config('request.jwt.claims', '', true);
  insert into public.email_queue (user_id, plant_id, kind, key) values (uy, 9000025, 'report_week', 'test:paused'), (uy, 9000021, 'report_week', 'test:active');
  perform pg_temp.eq('no mail for a paused plant', (select count(*)::int from public.email_queue where key = 'test:paused'), 0);
  perform pg_temp.eq('mail for an active plant', (select count(*)::int from public.email_queue where key = 'test:active'), 1);
  perform set_config('request.jwt.claims', json_build_object('sub', uy, 'role', 'authenticated')::text, true);
  perform pg_temp.raises('no room to start it', 'select public.api_plant_start(9000025)', 'no room');
  perform set_config('request.jwt.claims', '', true);

  -- The paywall's reader answers for the signed-in user only
  perform set_config('request.jwt.claims', json_build_object('sub', ur, 'role', 'authenticated')::text, true);
  q := public.api_billing_quote('family', 'yearly');
  perform pg_temp.eq('quote free plan',   q->>'plan', 'free');
  perform pg_temp.eq('quote free yearly', (q->>'dueNow')::int, 1990);
  perform pg_temp.eq('quote free home',   (public.api_billing_quote('home', 'monthly')->>'dueNow')::int, 99);
  perform set_config('request.jwt.claims', json_build_object('sub', uy, 'role', 'authenticated')::text, true);
  q := public.api_billing_quote('family', 'monthly', 3);
  perform pg_temp.eq('quote keeps own period', q->>'period', 'yearly');
  -- extra plants are no longer sold (0156): asking for 3 keeps the 1 held
  perform pg_temp.eq('quote yearly extras: none sold', (q->>'nextCharge')::int, 1990 + 1 * 588);
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
  ('00000000-0000-0000-0000-000000000063', 't3@t.test'), ('00000000-0000-0000-0000-000000000064', 't4@t.test');
insert into private.free_week_logins (sunsynk_username, user_id, started_at) values
  ('t1@login.test', '00000000-0000-0000-0000-000000000061', now() - interval '10 days'),
  ('t2@login.test', '00000000-0000-0000-0000-000000000062', now() - interval '2 days'),
  ('t3@login.test', '00000000-0000-0000-0000-000000000063', now() - interval '10 days'),
  ('t4@login.test', '00000000-0000-0000-0000-000000000064', now() - interval '7 days 30 minutes');
insert into public.plant_users (plant_id, user_id) values
  (9000061, '00000000-0000-0000-0000-000000000061'),   -- Free, week over: trimmed
  (9000062, '00000000-0000-0000-0000-000000000062'),   -- Free, still in its week
  (9000063, '00000000-0000-0000-0000-000000000063'),   -- Free, week over, but shared
  (9000063, '00000000-0000-0000-0000-0000000000a1'),   -- ... with a Family account
  (9000064, '00000000-0000-0000-0000-000000000064');   -- Free, week over 30 min ago: the day-7 report goes first (0182)
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
  perform pg_temp.eq('keep takes the login''s plants off the list (0139)', jsonb_array_length(st->'removePlants'), 0);
  perform pg_temp.eq('downgrade with too many plants books (0136)', public.api_billing_change('home')->>'nextPlan', 'home');
  perform public.api_billing_change('family');
  -- Remove login on Family: the login and its plants go now, as on Free (0139)
  perform pg_temp.eq('remove login now', public.api_link_remove('00000000-0000-0000-0000-0000000000f7')->>'result', 'removed');
  perform pg_temp.eq('its plants gone', (select count(*)::int from public.plant_users where account_id = '00000000-0000-0000-0000-0000000000f7'), 0);
  perform pg_temp.eq('login gone', (select count(*)::int from private.sunsynk_accounts where id = '00000000-0000-0000-0000-0000000000f7'), 0);
  perform pg_temp.eq('nothing left on the delete list', jsonb_array_length(public.api_billing_status()->'removePlants'), 0);
  perform public.api_billing_change('family');
  perform pg_temp.raises('not your login', 'select public.api_link_remove(''00000000-0000-0000-0000-000000000099'')', 'not your account');
  -- A switch to yearly is paid, not booked (0138); a cancel booked and undone
  perform set_config('request.jwt.claims', json_build_object('sub', uh, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('home monthly now', public.api_billing_status()->>'period', 'monthly');
  perform pg_temp.raises('switch not booked by the app', 'select public.api_billing_change(''home'', ''yearly'')', 'paid now');
  perform pg_temp.eq('switch quote for the app', (select q->>'dueNow' || ' ' || (q->>'switch') from public.api_billing_quote('home', 'yearly') q), '990 true');
  -- a cancel is undone by Keep (0176): no other change until then; one plan-kept email; rolled back after
  begin
    perform pg_temp.eq('cancel booked', public.api_billing_change('free')->>'nextPlan', 'free');
    perform pg_temp.eq('second cancel changes nothing', public.api_billing_change('free')->>'nextPlan', 'free');
    perform pg_temp.eq('second cancel not emailed', (select count(*)::int from public.email_queue where user_id = uh and kind = 'bill_change' and data->>'to' = 'free'), 1);
    perform pg_temp.raises('cancel: no period switch', 'select public.api_billing_change(''home'', ''yearly'')', 'cancelled');
    perform pg_temp.eq('undo cancel', public.api_billing_change('home', 'monthly')->>'nextPlan', null);
    perform public.api_billing_change('home', 'monthly');
    perform pg_temp.eq('undo cancel emailed once', (select count(*)::int || ' ' || min(data->>'plan') || ' ' || min(data->>'nextAmount')
                                                      from public.email_queue where user_id = uh and kind = 'bill_kept'), '1 home 99');
    raise exception 'undo' using errcode = 'T0001';
  exception when sqlstate 'T0001' then null;
  end;
  -- Each undo of a booked change is emailed; an undo with nothing booked is not (0134): Family's
  -- downgrade undone above, then its undo with nothing booked.
  perform pg_temp.eq('undo emails', (select count(*) from public.email_queue where user_id = uy and kind = 'bill_kept'), 1::bigint);
  perform set_config('request.jwt.claims', json_build_object('sub', uy, 'role', 'authenticated')::text, true);
  perform public.api_billing_change('family');
  perform pg_temp.eq('undo with nothing booked sends nothing', (select count(*) from public.email_queue where user_id = uy and kind = 'bill_kept'), 1::bigint);
  perform set_config('request.jwt.claims', json_build_object('sub', uh, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('undo email data', (select data->>'plan' from public.email_queue where user_id = uy and kind = 'bill_kept' limit 1), 'family');
  -- Free: Remove login goes at once
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values ('00000000-0000-0000-0000-0000000000f8', ur, 'r2@login.test');
  update public.plant_users set account_id = '00000000-0000-0000-0000-0000000000f8' where user_id = ur;
  perform set_config('request.jwt.claims', json_build_object('sub', ur, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('free remove is at once', public.api_link_remove('00000000-0000-0000-0000-0000000000f8')->>'result', 'removed');
  perform pg_temp.eq('free plant gone', (select count(*)::int from public.plant_users where user_id = ur), 0);
  perform set_config('request.jwt.claims', '', true);
end $$;
select pg_temp.eq('plan calls for signed-in users', has_function_privilege('authenticated', 'public.api_billing_change(text, text, bigint[])', 'execute'), true);
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
  perform pg_temp.eq('day 7 report: the free week''s first day', (select (data->>'from')::date from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000072' and kind = 'report_week'),
    timezone(public.plant_tz(9000072), now() - interval '7 days 2 hours')::date);
  perform pg_temp.eq('day 7 report: days the trim deletes', (select (data->>'days')::int from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000072' and kind = 'report_week'), 0);
  perform pg_temp.eq('nothing for a week long over', (select count(*)::int from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000063' and kind in ('free_week_soon', 'report_week')), 0);
  perform private.free_week_mail();
  perform pg_temp.eq('each goes once', (select count(*)::int from public.email_queue
    where user_id in ('00000000-0000-0000-0000-000000000071', '00000000-0000-0000-0000-000000000072') and kind in ('free_week_soon', 'report_week')), 2);
end $$;

-- Free week in the app and the day-2 email (0122)
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000073', 'd2@t.test'), ('00000000-0000-0000-0000-000000000074', 'd2done@t.test'),
  ('00000000-0000-0000-0000-000000000075', 'd2paid@t.test'), ('00000000-0000-0000-0000-000000000076', 'd2hid@t.test');
insert into private.free_week_logins (sunsynk_username, user_id, started_at) values
  ('d2@login.test', '00000000-0000-0000-0000-000000000073', now() - interval '2 days 2 hours'),
  ('d2done@login.test', '00000000-0000-0000-0000-000000000074', now() - interval '2 days 2 hours');
-- the setup email counts from the first plant's link (0163), on any plan, Hide or not
insert into public.plant_users (plant_id, user_id, linked_at) values
  (9000073, '00000000-0000-0000-0000-000000000073', now() - interval '2 days 2 hours'),
  (9000074, '00000000-0000-0000-0000-000000000074', now() - interval '2 days 2 hours'),
  (9000075, '00000000-0000-0000-0000-000000000075', now() - interval '2 days 2 hours'),
  (9000076, '00000000-0000-0000-0000-000000000076', now() - interval '2 days 2 hours');
insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
  values ('00000000-0000-0000-0000-000000000075', 'home', 'monthly', 1, '2026-12-01');
insert into public.profiles (user_id, prefs) values
  ('00000000-0000-0000-0000-000000000076', '{"firstSteps": {"9000076": {"done": true}}}')
  on conflict (user_id) do update set prefs = excluded.prefs;
insert into public.plant_config (plant_id, tariff_import, has_battery, battery_kwh, battery_reserve_pct, system_kwp) values
  (9000073, 3.1, true, null, 20, null), (9000074, 3.1, false, null, 20, 8),
  (9000075, 0, false, null, 20, 8), (9000076, 0, true, 10, 30, 8);
do $$
begin
  perform pg_temp.eq('steps left: size, reserve, panels', private.setup_steps_left('00000000-0000-0000-0000-000000000073', 9000073),
    array['size', 'reserve', 'panels']);
  perform pg_temp.eq('no battery, all set: none left', private.setup_steps_left('00000000-0000-0000-0000-000000000074', 9000074), '{}'::text[]);
  -- the reserve confirmed on the plant (0123) counts for every account on it
  update public.plant_config set battery_reserve_confirmed = true where plant_id = 9000073;
  perform pg_temp.eq('reserve confirmed on the plant', private.setup_steps_left('00000000-0000-0000-0000-000000000073', 9000073),
    array['size', 'panels']);
  update public.plant_config set battery_reserve_confirmed = false where plant_id = 9000073;
  perform private.free_week_mail();
  perform pg_temp.eq('day 2 lists only what is left', (select data->'steps' from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000073' and kind = 'free_week_setup'), '["size", "reserve", "panels"]'::jsonb);
  perform pg_temp.eq('day 2: nothing left, no email', (select count(*)::int from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000074' and kind = 'free_week_setup'), 0);
  perform pg_temp.eq('day 2 says the plant has a battery', (select data->'battery' from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000073' and kind = 'free_week_setup'), 'true'::jsonb);
  perform pg_temp.eq('day 2 on a paid plan, no battery', (select data from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000075' and kind = 'free_week_setup'), '{"steps": ["rate"], "battery": false}'::jsonb);
  perform pg_temp.eq('day 2 with the setup card hidden', (select data->'steps' from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000076' and kind = 'free_week_setup'), '["rate"]'::jsonb);
  perform pg_temp.eq('hidden card: app shows no steps', private.setup_steps_left('00000000-0000-0000-0000-000000000076', 9000076), '{}'::text[]);
  perform pg_temp.eq('day 5 says Home per month', (select (data->>'perMonth')::int from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000071' and kind = 'free_week_soon'), 83);
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000073","role":"authenticated"}', true);
  perform pg_temp.eq('api_me: free week end', (public.api_me()->>'freeWeekEndsAt') is not null, true);
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1","role":"authenticated"}', true);
  perform pg_temp.eq('api_me: paid has none', public.api_me()->'freeWeekEndsAt', 'null'::jsonb);
  perform set_config('request.jwt.claims', '', true);
  -- paying again refetches a trimmed plant's 60 days
  insert into private.free_trim_done (plant_id) values (9000073);
  update public.plant_config set backfill_next = null, backfill_until = null where plant_id in (9000073, 9000074);
  insert into private.billing (user_id, plan) values ('00000000-0000-0000-0000-000000000074', 'free');
  perform pg_temp.eq('free row: no refill', (select backfill_next from public.plant_config where plant_id = 9000074), null::date);
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
  values ('00000000-0000-0000-0000-000000000073', 'home', 'yearly', 1, '2027-11-01');
  perform pg_temp.eq('upgrade refills the trimmed plant', (select backfill_next from public.plant_config where plant_id = 9000073),
    (now() at time zone 'Africa/Johannesburg')::date - 60);
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
  (9000094, '00000000-0000-0000-0000-000000000091', '00000000-0000-0000-0000-000000000094', 'Home three', '2026-01-03'),
  (9000093, '00000000-0000-0000-0000-000000000092', null, 'N', '2026-01-01');
insert into private.inverters (sn, plant_id) values ('T-91', 9000091), ('T-92', 9000092), ('T-94', 9000094);
do $$
declare
  s constant uuid := '00000000-0000-0000-0000-000000000091';
  n constant uuid := '00000000-0000-0000-0000-000000000092';
  k constant uuid := '00000000-0000-0000-0000-000000000093';
  v_card constant jsonb := '{"authorization_code": "AUTH_t1", "card_type": "visa ", "last4": "4081", "reusable": true}';
  t date := private.billing_today();
  o jsonb; ref text; runs jsonb;
begin
  perform pg_temp.eq('s starts with two plants paused', (select count(*)::int from public.plant_users where user_id = s and paused), 2);
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
  perform pg_temp.eq('card label', (select data->>'card' from public.email_queue where user_id = s and kind = 'bill_upgraded'), 'Visa •••• 4081');
  perform pg_temp.eq('Home covers two of three plants', (select count(*)::int from public.plant_users where user_id = s and paused), 1);

  -- upgrade: Home to Family resumes the paused plant, charges the saved card
  o := public.billing_charge_open(s, 'family');
  perform pg_temp.eq('upgrade uses the saved card', o->>'card', 'AUTH_t1');
  perform pg_temp.eq('upgrade on day 1 is the whole difference', (o->>'amount')::int, 100);
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
    where x->>'card' = 'AUTH_t1' and (x->>'amount')::int = 199), 1);
  perform pg_temp.eq('date moved on', (select next_billing_date from private.billing where user_id = s), public.billing_step(t, 'monthly', extract(day from t)::int, 1));
  ref := (select x->>'reference' from jsonb_array_elements(runs) x where x->>'card' = 'AUTH_t1');
  perform pg_temp.eq('failure: next try day 1', public.billing_charge_failed(ref, 'declined')->>'nextTry', (t + 1)::text);
  perform pg_temp.eq('past due', (select state from private.billing where user_id = s), 'past_due');
  runs := public.billing_run(t + 1);
  perform pg_temp.eq('retry once a day', (select count(*)::int from jsonb_array_elements(public.billing_run(t + 1)) x where x->>'card' = 'AUTH_t1'), 0);
  ref := (select x->>'reference' from jsonb_array_elements(runs) x where x->>'card' = 'AUTH_t1');
  perform pg_temp.eq('retry same amount', (select amount from private.billing_charges where reference = ref), 199);
  update private.billing_charges set created_on = t + 1 where reference = ref;
  perform pg_temp.eq('day 1 fails: next day 3', public.billing_charge_failed(ref, 'declined')->>'nextTry', (t + 3)::text);
  perform pg_temp.eq('nothing on day 2', (select count(*)::int from jsonb_array_elements(public.billing_run(t + 2)) x where x->>'card' = 'AUTH_t1'), 0);
  ref := (select x->>'reference' from jsonb_array_elements(public.billing_run(t + 3)) x where x->>'card' = 'AUTH_t1');
  perform pg_temp.eq('day 3 fails: next day 7', public.billing_charge_failed(ref, 'declined')->>'nextTry', (t + 7)::text);
  ref := (select x->>'reference' from jsonb_array_elements(public.billing_run(t + 7)) x where x->>'card' = 'AUTH_t1');
  perform pg_temp.eq('day 7 is the last', public.billing_charge_failed(ref, 'declined')->>'nextTry', null::text);
  perform pg_temp.eq('four failure emails', (select count(*)::int from public.email_queue where user_id = s and kind = 'bill_failed'), 4);
  perform public.billing_run(t + 8);
  perform pg_temp.eq('day 8: Free', (select plan || state from private.billing where user_id = s), 'freeactive');
  perform pg_temp.eq('first plant kept', (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = s),
    '9000091:false,9000092:true,9000094:true');
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

  -- a renewal a run handed out but never reported is handed out again on the next run (0128)
  update private.billing set next_billing_date = t where user_id = s;
  perform public.billing_run(t);
  ref := (select reference from private.billing_charges where user_id = s and kind = 'renewal' and status = 'pending');
  perform pg_temp.eq('orphaned renewal handed out again',
    (select count(*)::int from jsonb_array_elements(public.billing_run(t + 1)) x where x->>'reference' = ref), 1);
  perform pg_temp.eq('still active while it is open', (select state from private.billing where user_id = s), 'active');

  -- no saved card: the renewal fails at once
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values (n, 'home', 'monthly', 5, t);
  perform pg_temp.eq('no card: not sent to Paystack', (select count(*)::int from jsonb_array_elements(public.billing_run(t)) x
    where (x->>'amount')::int = 99 and x->>'card' is null), 0);
  perform pg_temp.eq('no card: past due', (select state from private.billing where user_id = n), 'past_due');
  perform pg_temp.raises('past due cannot upgrade', format('select public.billing_charge_open(%L, %L)', n, 'family'), 'settle the failed payment first');
  -- nor cancel, nor switch period (0189, SOLAR-497); the plan as it is books nothing and is allowed
  perform pg_temp.raises('past due cannot cancel', format('select public.billing_book_change(%L, %L)', n, 'free'), 'pay the failed payment first');
  perform pg_temp.raises('past due cannot switch period', format('select public.billing_book_change(%L, %L, %L)', n, 'home', 'yearly'), 'pay the failed payment first');
  perform public.billing_book_change(n, 'home', 'monthly');
  perform pg_temp.eq('past due: nothing booked', (select coalesce(next_plan, '-') || coalesce(next_period, '-') from private.billing where user_id = n), '--');

  -- settle: pays the failed renewal with another card
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, past_due_since)
  values (k, 'home', 'yearly', 1, t + 300, 'past_due', t - 2);
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on)
  values ('psh_k1', k, 'renewal', 'home', 'yearly', 999, 'failed', t - 2, t - 2);
  o := public.billing_settle_open(k);
  perform pg_temp.eq('settle amount', (o->>'amount')::int, 999);
  perform public.billing_charge_paid(o->>'reference', v_card);
  perform pg_temp.eq('settled: active', (select state || coalesce(past_due_since::text, '-') from private.billing where user_id = k), 'active-');
  perform public.billing_book_change(k, 'free');
  perform pg_temp.eq('settled: a cancel books again', (select next_plan from private.billing where user_id = k), 'free');
  perform public.billing_book_change(k, 'home', 'yearly');
  perform pg_temp.eq('receipt', (select count(*)::int from public.email_queue where user_id = k and kind = 'bill_paid'), 1);
  perform pg_temp.raises('nothing left to settle', format('select public.billing_settle_open(%L)', k), 'nothing to pay');

  -- a booked cancel is emailed; its undo is emailed as kept, not as a change (0176)
  perform set_config('request.jwt.claims', json_build_object('sub', k, 'role', 'authenticated')::text, true);
  perform public.api_billing_change('free');
  perform pg_temp.eq('cancel emailed', (select data->>'to' from public.email_queue where user_id = k and kind = 'bill_change'), 'free');
  perform public.api_billing_change('home', 'yearly');
  perform pg_temp.eq('undo not emailed as a change', (select count(*)::int from public.email_queue where user_id = k and kind = 'bill_change'), 1);
  perform pg_temp.eq('undo emailed as kept', (select count(*)::int from public.email_queue where user_id = k and kind = 'bill_kept'), 1);
  perform set_config('request.jwt.claims', '', true);

  -- yearly renewal notice 60 days before
  update private.billing set next_billing_date = t + 60 where user_id = k;
  perform public.billing_run(t);
  perform pg_temp.eq('renewal notice', (select (data->>'amount')::int from public.email_queue where user_id = k and kind = 'bill_renewal_notice'), 990);
end $$;
select pg_temp.eq('authenticated cannot mark paid', has_function_privilege('authenticated', 'public.billing_charge_paid(text, jsonb, boolean, bigint, text, timestamptz)', 'execute'), false);
select pg_temp.eq('charges closed', has_table_privilege('authenticated', 'private.billing_charges', 'select'), false);

-- Only service_role may call the rules
select pg_temp.eq('authenticated cannot', has_function_privilege('authenticated', 'public.billing_amount_due(uuid)', 'execute'), false);
select pg_temp.eq('service_role can',     has_function_privilege('service_role', 'public.billing_amount_due(uuid)', 'execute'), true);
select pg_temp.eq('billing table closed', has_table_privilege('authenticated', 'private.billing', 'select'), false);

-- Comped (0115, switched by hand with billing_set_comped since 0130): Family, never billed.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-000000000081', 'old@t.test');
insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values ('00000000-0000-0000-0000-000000000082', '00000000-0000-0000-0000-000000000081', 'old@login.test');
insert into public.plant_users (plant_id, user_id, account_id, paused) values
  (9000081, '00000000-0000-0000-0000-000000000081', '00000000-0000-0000-0000-000000000082', false),
  (9000082, '00000000-0000-0000-0000-000000000081', '00000000-0000-0000-0000-000000000082', true);
do $$
declare u constant uuid := '00000000-0000-0000-0000-000000000081';
begin
  perform public.billing_set_comped(u, true);
  perform pg_temp.eq('comped account on Family', (select plan || ' ' || comped from private.billing where user_id = u), 'family true');
  perform pg_temp.eq('never billed', public.billing_amount_due(u), 0);
  perform pg_temp.eq('no limit', (public.billing_may_link(u, 'x@login.test', array[1, 1, 1])->>'ok')::boolean, true);
  perform pg_temp.raises('no plan changes', format('select public.billing_book_change(%L, %L)', u, 'home'), 'free of charge');
  perform pg_temp.raises('no renewal', format('select public.billing_renew(%L)', u), 'nothing to renew');
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('status says comped', (public.api_billing_status()->>'comped')::boolean, true);
  perform public.api_plant_start(9000082);
  perform pg_temp.eq('a stopped plant starts', (select count(*)::int from public.plant_users where user_id = u and paused), 0);
  perform pg_temp.eq('remove login at once', public.api_link_remove('00000000-0000-0000-0000-000000000082')->>'result', 'removed');
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.eq('not trimmed', (select count(*)::int from public.free_trimmed_plants() x where x in (9000081, 9000082)), 0);
end $$;

-- Invoices keep every payment, with its status (0184, SOLAR-489). Disputes are not shown:
-- an open one stays paid, a lost one is written as a refund.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000b9', 'inv@t.test');
insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on, settled_at,
                                     error, refund_status, refunded_cents, dispute, dispute_lost) values
  ('psh_i1', '00000000-0000-0000-0000-0000000000b9', 'start',   'home',   'monthly', 49, 'paid', '2026-06-01', '2026-06-01', '2026-06-01 10:00', null, null, null, null, false),
  ('psh_i2', '00000000-0000-0000-0000-0000000000b9', 'upgrade', 'family', 'monthly', 50, 'paid', '2026-06-02', '2026-06-02', '2026-06-02 10:00', 'refund: paid plants did not start', 'done', 5000, null, false),
  ('psh_i3', '00000000-0000-0000-0000-0000000000b9', 'renewal', 'home',   'monthly', 49, 'paid', '2026-07-01', '2026-07-01', '2026-07-01 10:00', 'card not reusable: not saved', null, null, null, false),
  ('psh_i4', '00000000-0000-0000-0000-0000000000b9', 'renewal', 'home',   'monthly', 49, 'paid', '2026-08-01', '2026-08-01', '2026-08-01 10:00', null, 'asked', null, null, false),
  ('psh_i5', '00000000-0000-0000-0000-0000000000b9', 'renewal', 'home',   'monthly', 49, 'paid', '2026-09-01', '2026-09-01', '2026-09-01 10:00', null, 'done', 2000, null, false),
  ('psh_i6', '00000000-0000-0000-0000-0000000000b9', 'renewal', 'home',   'monthly', 49, 'paid', '2026-10-01', '2026-10-01', '2026-10-01 10:00', null, 'done', 4900, 'lost', true),
  ('psh_i7', '00000000-0000-0000-0000-0000000000b9', 'renewal', 'home',   'monthly', 49, 'paid', '2026-11-01', '2026-11-01', '2026-11-01 10:00', null, 'failed', null, 'awaiting-merchant-feedback', false),
  ('psh_i8', '00000000-0000-0000-0000-0000000000b9', 'card',    'home',   'monthly', 1,  'paid', '2026-11-02', '2026-11-02', '2026-11-02 10:00', null, 'done', 100, null, false),
  ('psh_i9', '00000000-0000-0000-0000-0000000000b9', 'renewal', 'home',   'monthly', 49, 'failed', '2026-11-03', '2026-11-03', '2026-11-03 10:00', 'declined', null, null, null, false);
do $$
declare pays jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000b9', 'role', 'authenticated')::text, true);
  pays := public.api_billing_status()->'payments';
  perform set_config('request.jwt.claims', '', true);
  -- newest first, six at most: i7..i2 (i1 is the seventh; card check and failed charge left out)
  perform pg_temp.eq('invoice statuses', (select string_agg(p->>'status', ' ' order by o) from jsonb_array_elements(pays) with ordinality x(p, o)),
    'paid refunded part_refunded refunded paid refunded');
  perform pg_temp.eq('refunded keeps amount', (pays->1->>'amount')::int, 49);
  -- prev skips the upgrade that applied nothing (refunded as 'refund: ...')
  perform pg_temp.eq('prev skips unapplied', pays->4->>'prev', 'home');
end $$;

-- The pick as a whole set (0186, SOLAR-486): Family with 4 plants books Home, then ticks 2.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000e5', 'pick@t.test');
insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
  values ('00000000-0000-0000-0000-0000000000e5', 'family', 'monthly', 1, '2026-12-01');
insert into public.plant_users (plant_id, user_id, linked_at, paused) values
  (9000501, '00000000-0000-0000-0000-0000000000e5', '2026-01-01', false),
  (9000502, '00000000-0000-0000-0000-0000000000e5', '2026-01-02', false),
  (9000503, '00000000-0000-0000-0000-0000000000e5', '2026-01-03', false),
  (9000504, '00000000-0000-0000-0000-0000000000e5', '2026-01-04', false),
  (9000505, '00000000-0000-0000-0000-0000000000e5', '2026-01-05', true);
do $$
declare b private.billing;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000e5', 'role', 'authenticated')::text, true);
  perform pg_temp.raises('no pick without a booked change', 'select public.api_billing_keep_set(''{9000501,9000502}'')', 'nothing to pick');
  perform public.api_billing_change('home');
  select * into b from private.billing where user_id = '00000000-0000-0000-0000-0000000000e5';
  perform pg_temp.eq('no pick: first linked kept', private.billing_drops(b), '{9000503,9000504}'::bigint[]);
  perform pg_temp.raises('one too few', 'select public.api_billing_keep_set(''{9000503}'')', 'pick 2 plants');
  perform pg_temp.raises('one too many', 'select public.api_billing_keep_set(''{9000501,9000502,9000503}'')', 'pick 2 plants');
  perform pg_temp.raises('a stopped plant', 'select public.api_billing_keep_set(''{9000501,9000505}'')', 'pick 2 plants');
  perform pg_temp.raises('a plant not yours', 'select public.api_billing_keep_set(''{9000501,9000011}'')', 'pick 2 plants');
  perform pg_temp.raises('the same plant twice', 'select public.api_billing_keep_set(''{9000501,9000501}'')', 'pick 2 plants');
  -- untick 9000501, tick 9000504: 9000501 is the one that stops, not the last picked
  perform public.api_billing_keep_set('{9000502,9000504}');
  select * into b from private.billing where user_id = '00000000-0000-0000-0000-0000000000e5';
  perform pg_temp.eq('the unticked plant stops', private.billing_drops(b), '{9000501,9000503}'::bigint[]);
  perform pg_temp.eq('no email for a pick', (select count(*)::int from public.email_queue where user_id = '00000000-0000-0000-0000-0000000000e5' and kind = 'bill_change'), 1);
  -- a cancel keeps 1
  perform public.api_billing_change('free');
  perform public.api_billing_keep_set('{9000503}');
  select * into b from private.billing where user_id = '00000000-0000-0000-0000-0000000000e5';
  perform pg_temp.eq('cancel keeps the ticked one', private.billing_drops(b), '{9000501,9000502,9000504}'::bigint[]);
  perform set_config('request.jwt.claims', '', true);
end $$;
-- A cancel in a paid year picks the same way (0186): Home with its year paid from 1 Dec.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000e6', 'paidyear@t.test');
insert into private.billing (user_id, plan, period, billing_day, next_billing_date, prepaid_on)
  values ('00000000-0000-0000-0000-0000000000e6', 'home', 'monthly', 1, '2026-12-01', '2026-12-01');
insert into public.plant_users (plant_id, user_id, linked_at) values
  (9000601, '00000000-0000-0000-0000-0000000000e6', '2026-01-01'),
  (9000602, '00000000-0000-0000-0000-0000000000e6', '2026-01-02');
insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values ('00000000-0000-0000-0000-0000000000f6', '00000000-0000-0000-0000-0000000000e6', 'paidyear@login.test');
update public.plant_users set account_id = '00000000-0000-0000-0000-0000000000f6' where user_id = '00000000-0000-0000-0000-0000000000e6';
do $$
declare b private.billing; u constant uuid := '00000000-0000-0000-0000-0000000000e6';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform public.api_billing_change('free');
  select * into b from private.billing where user_id = u;
  perform pg_temp.eq('paid year: cancel stops the second plant', private.billing_drops(b), '{9000602}'::bigint[]);
  perform pg_temp.eq('paid year: Home''s room holds for starts', private.billing_next_room(b), null::int);
  perform pg_temp.eq('paid year: deleted the day the year ends (0188)',
    (select (p->>'remove_on')::date from public.api_link_status() s, jsonb_array_elements(s.plants) p where (p->>'plant_id')::bigint = 9000602), date '2027-12-01');
  perform pg_temp.eq('paid year: email deletion date',
    (select (data->>'deleteOn')::date from public.email_queue where user_id = u and kind = 'bill_change'), date '2027-12-01');
  perform public.api_billing_keep_set('{9000602}');
  select * into b from private.billing where user_id = u;
  perform pg_temp.eq('paid year: the ticked plant stays', private.billing_drops(b), '{9000601}'::bigint[]);
  perform set_config('request.jwt.claims', '', true);
  -- the year starts as paid: the pick waits for its end
  perform public.billing_renew(u);
  select * into b from private.billing where user_id = u;
  perform pg_temp.eq('paid year: plan still Home', b.plan, 'home');
  perform pg_temp.eq('paid year: pick kept over the start', private.billing_drops(b), '{9000601}'::bigint[]);
  perform pg_temp.eq('paid year: both plants still collect', (select count(*)::int from public.plant_users where user_id = u and not paused), 2);
end $$;
-- A smaller paid plan deletes its stopped plants on the billing date (0187, SOLAR-492).
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000e7', 'downgrade@t.test');
insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
  values ('00000000-0000-0000-0000-0000000000e7', 'family', 'monthly', 1, '2026-12-01');
insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values ('00000000-0000-0000-0000-00000000f7a0', '00000000-0000-0000-0000-0000000000e7', 'downgrade@login.test');
insert into public.plant_users (plant_id, user_id, linked_at, account_id) values
  (9000701, '00000000-0000-0000-0000-0000000000e7', '2026-01-01', '00000000-0000-0000-0000-00000000f7a0'),
  (9000702, '00000000-0000-0000-0000-0000000000e7', '2026-01-02', '00000000-0000-0000-0000-00000000f7a0'),
  (9000703, '00000000-0000-0000-0000-0000000000e7', '2026-01-03', '00000000-0000-0000-0000-00000000f7a0');
do $$
declare b private.billing; u constant uuid := '00000000-0000-0000-0000-0000000000e7';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform public.api_billing_change('home');
  perform pg_temp.eq('downgrade: deleted on the billing date',
    (select (p->>'remove_on')::date from public.api_link_status() s, jsonb_array_elements(s.plants) p where (p->>'plant_id')::bigint = 9000703), date '2026-12-01');
  perform pg_temp.eq('downgrade: email deletion date',
    (select (data->>'deleteOn')::date from public.email_queue where user_id = u and kind = 'bill_change'), date '2026-12-01');
  perform set_config('request.jwt.claims', '', true);
  perform public.billing_renew(u);
  select * into b from private.billing where user_id = u;
  perform pg_temp.eq('downgrade: on Home', b.plan, 'home');
  perform pg_temp.eq('downgrade: stopped plant gone on the day', (select count(*)::int from public.plant_users where user_id = u and plant_id = 9000703), 0);
  perform pg_temp.eq('downgrade: kept plants collect', (select count(*)::int from public.plant_users where user_id = u and not paused), 2);
  perform pg_temp.eq('downgrade: nothing booked for later', coalesce(cardinality(b.plants_to_remove), 0), 0);
end $$;
-- a cancel still keeps 30 days (0146): the paid-year case above reads year end + 30
select pg_temp.eq('keep set is for signed-in users', has_function_privilege('anon', 'public.api_billing_keep_set(bigint[])', 'execute'), false);

\set QUIET off
do $$ begin
  if exists (select 1 from pg_temp.fails) then
    raise exception E'billing tests failed:\n%', (select string_agg(what, E'\n' order by n) from pg_temp.fails);
  end if;
end $$;
select 'PASS' as billing_tests;
rollback;
