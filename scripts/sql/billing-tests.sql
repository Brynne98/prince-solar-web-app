-- Billing rule tests (SOLAR-208 part 1, rules as of 0130). Needs the local database at
-- the latest migration. Runs every case inside one transaction, then rolls it all back.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/sql/billing-tests.sql
-- Exit code decides: any wrong case raises.
\set QUIET on
begin;
-- Fixture links are ticked in link order while the plan has places (0197): the owner's
-- pick, made here for every plant_users insert. The pick's own rules are at the end.
create function pg_temp.tick() returns trigger language plpgsql as $$
begin
  if not new.paused then perform private.plant_pick_add(new.user_id, new.plant_id, new.plant_name); end if;
  return new;
end $$;
create trigger a_test_tick before insert on public.plant_users for each row execute function pg_temp.tick();
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
  perform pg_temp.eq('room with no plan',   public.billing_room('free'), 5);
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
  perform pg_temp.eq('no plan, 2nd plant', (public.billing_may_link(ur, 'r@login.test', array[1])->>'ok')::boolean, true);
  perform pg_temp.eq('home 3rd plant',    public.billing_may_link(ua, 'a@login.test', array[1])->>'reason', 'upgrade_needed');
  delete from public.plant_users where user_id = ur;
  perform pg_temp.eq('no plan, 3 plants', (public.billing_may_link(ur, 'i@login.test', array[1, 1, 1])->>'ok')::boolean, true);
  perform pg_temp.eq('free 1st plant',    (public.billing_may_link(ur, 'r@login.test', array[1])->>'ok')::boolean, true);

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
  perform pg_temp.raises('no room to tick it', 'select public.api_plant_pick(array[9000025])', 'no room');
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

-- No plan after the free week (0204, 0205): the plant is not read, and its readings go 30 days after the week ends
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000061', 't1@t.test'), ('00000000-0000-0000-0000-000000000062', 't2@t.test'),
  ('00000000-0000-0000-0000-000000000063', 't3@t.test'), ('00000000-0000-0000-0000-000000000064', 't4@t.test'),
  ('00000000-0000-0000-0000-000000000065', 't5@t.test');
insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
  values ('00000000-0000-0000-0000-000000000065', 'home', 'monthly', 1, current_date + 20);
insert into private.free_week_logins (sunsynk_username, user_id, started_at) values
  ('t1@login.test', '00000000-0000-0000-0000-000000000061', now() - interval '10 days'),
  ('t2@login.test', '00000000-0000-0000-0000-000000000062', now() - interval '2 days'),
  ('t3@login.test', '00000000-0000-0000-0000-000000000063', now() - interval '40 days'),
  ('t4@login.test', '00000000-0000-0000-0000-000000000064', now() - interval '37 days' + interval '1 hour');
insert into public.plant_users (plant_id, user_id) values
  (9000061, '00000000-0000-0000-0000-000000000061'),   -- no plan, week over 3 days ago: not read, kept
  (9000062, '00000000-0000-0000-0000-000000000062'),   -- no plan, still in its week: read
  (9000063, '00000000-0000-0000-0000-000000000063'),   -- no plan, week over 33 days ago, but shared
  (9000063, '00000000-0000-0000-0000-000000000065'),   -- ... with a Home account: read, kept
  (9000064, '00000000-0000-0000-0000-000000000064');   -- no plan, one hour short of day 37
insert into private.plant_week (plant_id, started_at) values
  (9000061, now() - interval '10 days'), (9000062, now() - interval '2 days'),
  (9000063, now() - interval '40 days'), (9000064, now() - interval '37 days' + interval '1 hour');
insert into public.plant_config (plant_id, timezone, backfill_next, backfill_until, temp_next)
  values (9000061, 'Africa/Johannesburg', null, null, null), (9000064, 'Africa/Johannesburg', current_date - 50, current_date - 1, current_date - 40);
insert into public.agg_minute (plant_id, ts)
  select p, extract(epoch from now() - h * interval '1 hour')::bigint
    from unnest(array[9000061, 9000062, 9000063, 9000064, 9000021]) p, unnest(array[1, 23, 25, 48, 24 * 20]) h;
insert into public.plant_energy (plant_id, bucket, period)
  select p, b, d from unnest(array[9000064, 9000062]) p,
    (values ('day', public.today_tz('Africa/Johannesburg')), ('day', public.today_tz('Africa/Johannesburg') - 1),
            ('day', public.today_tz('Africa/Johannesburg') - 5), ('month', date_trunc('month', public.today_tz('Africa/Johannesburg'))::date)) v(b, d);
insert into public.grid_off (plant_id, started_at, ended_at, last_off_at, minutes_off) values
  (9000064, now() - interval '3 days', now() - interval '3 days' + interval '1 hour', now() - interval '3 days', 60),
  (9000064, now() - interval '2 hours', null, now() - interval '1 hour', 60);

do $$
declare r jsonb;
begin
  perform pg_temp.eq('read: in its week, or shared with a payer', (select array_agg(x order by x) from public.live_plants() x where x between 9000061 and 9000064),
                     array[9000062, 9000063]::bigint[]);
  perform pg_temp.eq('poll list has the same', (select array_agg(plant_id order by plant_id) from public.poll_jobs(0, 1) where plant_id between 9000061 and 9000064),
                     (select array_agg(pu.plant_id order by pu.plant_id) from public.plant_users pu join private.sunsynk_accounts a on a.id = pu.account_id and a.status = 'active'
                       where pu.plant_id in (9000062, 9000063)));
  r := private.unpaid_delete();
  perform pg_temp.eq('nothing deleted before day 37', (select count(*)::int from public.agg_minute where plant_id in (9000061, 9000064)), 10);
  perform pg_temp.eq('in its week keeps all', (select count(*)::int from public.agg_minute where plant_id = 9000062), 5);
  perform pg_temp.eq('shared with a payer keeps all', (select count(*)::int from public.agg_minute where plant_id = 9000063), 5);
  -- two hours on: day 37 has passed for 9000064
  update private.free_week_logins set started_at = started_at - interval '2 hours' where user_id = '00000000-0000-0000-0000-000000000064';
  r := private.unpaid_delete();
  perform pg_temp.eq('delete ran on one plant', (r->>'plants')::int, 1);
  perform pg_temp.eq('readings gone on day 37', (select count(*)::int from public.agg_minute where plant_id = 9000064), 0);
  perform pg_temp.eq('day totals gone', (select count(*)::int from public.plant_energy where plant_id = 9000064), 0);
  perform pg_temp.eq('grid-off gone', (select count(*)::int from public.grid_off where plant_id = 9000064), 0);
  perform pg_temp.eq('import bookmarks cleared', (select row(backfill_next, backfill_until, temp_next)::text from public.plant_config where plant_id = 9000064), '(,,)');
  perform pg_temp.eq('the link and the tick stay', (select count(*)::int from public.plant_users pu join private.plant_picks k using (user_id, plant_id) where pu.plant_id = 9000064), 1);
  perform pg_temp.eq('3 days past the week: kept', (select count(*)::int from public.agg_minute where plant_id = 9000061), 5);
  perform pg_temp.eq('other plant totals kept', (select count(*)::int from public.plant_energy where plant_id = 9000062), 4);
  perform pg_temp.eq('family keeps all', (select count(*)::int from public.agg_minute where plant_id = 9000021 and ts > extract(epoch from now() - interval '21 days')), 5);
  perform pg_temp.eq('a second run finds nothing', (private.unpaid_delete()->>'plants')::int, 0);
  -- Paying: read again, and the last 60 days are fetched
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
    values ('00000000-0000-0000-0000-000000000061', 'home', 'monthly', 1, current_date + 30);
  perform pg_temp.eq('paid: read again', (select count(*)::int from public.live_plants() x where x = 9000061), 1);
  perform pg_temp.eq('paid: 60 days booked', (select backfill_next from public.plant_config where plant_id = 9000061),
                     (now() at time zone 'Africa/Johannesburg')::date - 60);
  -- The plan ends (a cancel's end date): not read, kept 30 days from then
  update private.billing set plan = 'free', period = null, billing_day = null, next_billing_date = null where user_id = '00000000-0000-0000-0000-000000000061';
  perform pg_temp.eq('plan ended: not read', (select count(*)::int from public.live_plants() x where x = 9000061), 0);
  perform pg_temp.eq('plan ended: the time is kept', (select ended_at > now() - interval '1 minute' from private.billing where user_id = '00000000-0000-0000-0000-000000000061'), true);
  perform private.unpaid_delete();
  perform pg_temp.eq('plan ended: kept at first', (select count(*)::int from public.agg_minute where plant_id = 9000061), 5);
  update private.billing set ended_at = now() - interval '30 days 1 hour' where user_id = '00000000-0000-0000-0000-000000000061';
  update private.free_week_logins set started_at = now() - interval '60 days' where user_id = '00000000-0000-0000-0000-000000000061';
  perform private.unpaid_delete();
  perform pg_temp.eq('plan ended: gone 30 days on', (select count(*)::int from public.agg_minute where plant_id = 9000061), 0);
end $$;
select pg_temp.eq('read list is server only', has_function_privilege('authenticated', 'public.live_plants()', 'execute'), false);

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
  perform pg_temp.eq('no plan and no week on record: no report either (0206)',
    (select count(*)::int from public.email_queue where key = 'test:old-free-report'), 0);
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
  perform pg_temp.eq('day 7 report: the plants ticked', (select (data->>'plants')::int from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000072' and kind = 'report_week'), 1);
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
insert into public.profiles (user_id, prefs) values
  ('00000000-0000-0000-0000-000000000076', '{"firstSteps": {"9000076": {"done": true}}}')
  on conflict (user_id) do update set prefs = excluded.prefs;
insert into public.plant_config (plant_id, tariff_import, has_battery, battery_kwh, battery_reserve_pct, system_kwp) values
  (9000073, 3.1, true, null, 20, null), (9000074, 3.1, false, null, 20, 8),
  (9000075, 0, false, null, 20, 8), (9000076, 0, true, 10, 30, 8);
insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
  values ('00000000-0000-0000-0000-000000000075', 'home', 'monthly', 1, '2026-12-01');
-- 73, 74 and 76 have no plan: day 2 of their free week, so their plants are read (0216)
insert into private.plant_week (plant_id, started_at) select x, now() - interval '2 days 2 hours' from unnest(array[9000073, 9000074, 9000076]) x
  on conflict (plant_id) do update set started_at = excluded.started_at;
insert into private.free_week_logins (sunsynk_username, user_id, started_at)
  select 'w' || x, ('00000000-0000-0000-0000-0000000000' || x)::uuid, now() - interval '2 days 2 hours' from unnest(array[73, 74, 76]) x
  on conflict (user_id) do update set started_at = excluded.started_at, over_at = null, over_why = null;
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
  -- paying fetches the 60 days of a plant that was not read (0205): 73's free week is over
  update private.plant_week set started_at = now() - interval '8 days' where plant_id = 9000073;
  update public.plant_config set backfill_next = null, backfill_until = null where plant_id in (9000073, 9000074);
  insert into private.billing (user_id, plan) values ('00000000-0000-0000-0000-000000000074', 'free');
  perform pg_temp.eq('free row: no refill', (select backfill_next from public.plant_config where plant_id = 9000074), null::date);
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
  values ('00000000-0000-0000-0000-000000000073', 'home', 'yearly', 1, '2027-11-01');
  perform pg_temp.eq('paying refills the plant that was not read', (select backfill_next from public.plant_config where plant_id = 9000073),
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
  perform pg_temp.eq('s starts with its three plants running', (select count(*)::int from public.plant_users where user_id = s and paused), 0);
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
  -- Home has 2 places: the plant over it is locked, the first linked kept (0205)
  perform pg_temp.eq('Home paid: the third plant is locked', (select string_agg(plant_id::text, ',') from public.plant_users where user_id = s and paused), '9000094');
  perform pg_temp.eq('Home paid: it keeps its tick without its place', (select held from private.plant_picks where user_id = s and plant_id = 9000094), false);
  perform pg_temp.eq('Home paid: its history is booked to go', (select count(*)::int from private.plant_wipe where plant_id = 9000094), 1);
  perform set_config('request.jwt.claims', json_build_object('sub', s, 'role', 'authenticated')::text, true);
  perform public.api_plant_pick(array[9000092]);
  perform pg_temp.raises('Home is full: no third tick', 'select public.api_plant_pick(array[9000094])', 'no room');
  perform set_config('request.jwt.claims', '', true);
  perform pg_temp.eq('Home covers two of three plants', (select count(*)::int from public.plant_users where user_id = s and paused), 1);

  -- upgrade: Home to Family for the locked plant starts it, charges the saved card
  o := public.billing_charge_open(s, 'family', p_plants => array[9000094]::bigint[]);
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
  -- day 8 ends like a cancel (SOLAR-564): every plant stays as it was, nothing booked, the pay screen at once
  perform pg_temp.eq('day 8: plants as they were', (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = s),
    '9000091:false,9000092:false,9000094:false');
  perform pg_temp.eq('day 8: nothing booked', (select coalesce(cardinality(plants_to_remove), 0)::text || coalesce(remove_on::text, '-') from private.billing where user_id = s), '0-');
  perform pg_temp.eq('day 8: no 30 days of reading', (select keep_until is null and ended_at is not null from private.billing where user_id = s), true);
  perform pg_temp.eq('day 8 email', (select data->>'from' || '/' || (data->>'deleteOn') || '/' || (data->>'plants') from public.email_queue where user_id = s and kind = 'bill_free'),
    'family/' || (t + 38) || '/' || (select count(*) from private.plant_picks where user_id = s));
  perform public.billing_run(t + 35);
  perform pg_temp.eq('no removal warning', (select count(*)::int from public.email_queue where user_id = s and kind = 'bill_removal_soon'), 0);
  perform public.billing_run(t + 38);
  perform pg_temp.eq('day 38: every plant still linked', (select count(*)::int from public.plant_users where user_id = s), 3);

  -- paying Family after the plan ended starts the ticked plants again; a plant never ticked stays locked
  o := public.billing_charge_open(s, 'family', 'monthly');
  insert into public.plant_users (plant_id, user_id, account_id, plant_name, linked_at, paused) values
    (9000095, s, '00000000-0000-0000-0000-000000000094', 'Home four', '2026-01-04', true);
  perform public.billing_charge_paid(o->>'reference', v_card);
  perform pg_temp.eq('resumed after Free', (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = s),
    '9000091:false,9000092:false,9000094:false,9000095:true');
  delete from public.plant_users where plant_id = 9000095;

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
  perform public.api_plant_pick(array[9000082]);
  perform pg_temp.eq('comped plants are read', (select count(*)::int from public.live_plants() x where x in (9000081, 9000082)), 2);
  perform pg_temp.eq('a stopped plant starts', (select count(*)::int from public.plant_users where user_id = u and paused), 0);
  perform pg_temp.eq('remove login at once', public.api_link_remove('00000000-0000-0000-0000-000000000082')->>'result', 'removed');
  perform set_config('request.jwt.claims', '', true);
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
  -- a cancel stops no plant: nothing is read after it, and the history goes 30 days on (0205)
  perform public.api_billing_change('free');
  select * into b from private.billing where user_id = '00000000-0000-0000-0000-0000000000e5';
  perform pg_temp.eq('cancel drops no plant', private.billing_drops(b), '{}'::bigint[]);
  perform pg_temp.raises('cancel: nothing to pick', 'select public.api_billing_keep_set(''{9000503}'')', 'nothing to pick');
  perform set_config('request.jwt.claims', '', true);
end $$;
-- A cancel in a paid year (0186): Home with its year paid from 1 Dec. No plant stops.
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
  perform pg_temp.eq('paid year: cancel stops no plant', private.billing_drops(b), '{}'::bigint[]);
  perform pg_temp.eq('paid year: Home''s room holds for starts', private.billing_next_room(b), null::int);
  perform pg_temp.eq('paid year: no plant booked for deletion',
    (select (p->>'remove_on')::date from public.api_link_status() s, jsonb_array_elements(s.plants) p where (p->>'plant_id')::bigint = 9000602), null::date);
  perform set_config('request.jwt.claims', '', true);
  -- the year starts as paid: the pick waits for its end
  perform public.billing_renew(u);
  select * into b from private.billing where user_id = u;
  perform pg_temp.eq('paid year: plan still Home', b.plan, 'home');
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
-- ---------------------------------------------------------------------------
-- The plant pick (0197, SOLAR-537): the owner ticks which plants run, then one change
-- per 90 days. p = Home, one login with 3 plants, linked the way link-sunsynk links it.
-- q = Free, a login with one plant.
-- ---------------------------------------------------------------------------
drop trigger a_test_tick on public.plant_users;
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000009a1', 'p@t.test'), ('00000000-0000-0000-0000-0000000009a2', 'q@t.test');
insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values
  ('00000000-0000-0000-0000-0000000009a1', 'home', 'monthly', 1, '2026-12-01');
insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values
  ('00000000-0000-0000-0000-0000000009b1', '00000000-0000-0000-0000-0000000009a1', 'p@login.test'),
  ('00000000-0000-0000-0000-0000000009b2', '00000000-0000-0000-0000-0000000009a2', 'q@login.test');
do $$
declare
  p constant uuid := '00000000-0000-0000-0000-0000000009a1';
  q constant uuid := '00000000-0000-0000-0000-0000000009a2';
  acc constant uuid := '00000000-0000-0000-0000-0000000009b1';
  three constant jsonb := '[{"plant_id": 9000901, "plant_name": "One"}, {"plant_id": 9000902, "plant_name": "Two"}, {"plant_id": 9000903, "plant_name": "Three"}]';
  v_card constant jsonb := '{"authorization_code": "AUTH_p1", "card_type": "visa ", "last4": "4081", "reusable": true}';
  t date := private.billing_today();
  o jsonb;
  sh uuid;
begin
  -- link: nothing runs until the owner ticks
  perform public.plant_users_upsert(p, acc, three);
  perform pg_temp.eq('pick: 3 plants link locked', (select count(*)::int from public.plant_users where user_id = p and paused), 3);
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('pick: all three can start', (select count(*)::int from public.api_link_status() s, jsonb_array_elements(s.plants) x where (x->>'can_start')::boolean), 3);
  perform pg_temp.raises('pick: 3 ticks on Home refused', 'select public.api_plant_pick(array[9000901, 9000902, 9000903])', 'no room');
  perform pg_temp.eq('pick: a refused pick ticks none', (select count(*)::int from private.plant_picks where user_id = p), 0);
  perform pg_temp.raises('pick: another account''s plant refused', 'select public.api_plant_pick(array[9000001])', 'not linked');
  perform public.api_plant_pick(array[9000901, 9000902]);
  perform pg_temp.eq('pick: 2 ticked run', (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = p),
    '9000901:false,9000902:false,9000903:true');
  perform pg_temp.eq('pick: the third is locked, no place', (select count(*)::int from public.api_link_status() s, jsonb_array_elements(s.plants) x where (x->>'can_start')::boolean), 0);
  perform pg_temp.raises('pick: third tick refused', 'select public.api_plant_pick(array[9000903])', 'no room');

  -- the change: one out, one in; the first is ready at once
  perform pg_temp.eq('change: ready from day one', public.api_plant_picks()->>'change_on', null::text);
  perform public.api_plant_change(9000901, 9000903);
  perform pg_temp.eq('change: one out, one in', (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = p),
    '9000901:true,9000902:false,9000903:false');
  perform pg_temp.eq('change: the plant out loses its history at once', (select count(*)::int from private.plant_wipe where plant_id = 9000901), 1);
  perform pg_temp.eq('change: and its tick', (select string_agg(plant_id::text, ',' order by plant_id) from private.plant_picks where user_id = p), '9000902,9000903');
  perform pg_temp.eq('change: next one opens 90 days on', public.api_plant_picks()->>'change_on',
    (t + 90)::text);
  perform pg_temp.raises('change: a second is refused with the date', 'select public.api_plant_change(9000902, 9000901)',
    'next change ' || (t + 90));
  perform pg_temp.eq('change: the refused one changed nothing', (select count(*)::int from public.plant_users where user_id = p and not paused and plant_id in (9000902, 9000903)), 2);
  update private.plant_change set changed_on = t - 89 where user_id = p;
  perform pg_temp.raises('change: still refused on day 89', 'select public.api_plant_change(9000902, 9000901)', 'next change');

  -- cancel, then buy again: the same plants come back, the change is not used
  perform public.api_billing_change('free', null, array[9000902]);
  perform set_config('request.jwt.claims', '', true);
  update private.billing set next_billing_date = t where user_id = p;
  perform public.billing_run(t);
  perform pg_temp.eq('cancel: no plan, and no plant is stopped or deleted',
    (select plan from private.billing where user_id = p) || ' ' ||
    (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = p), 'free 9000901:true,9000902:false,9000903:false');
  perform pg_temp.eq('cancel: nothing is read', (select count(*)::int from public.live_plants() x where x in (9000902, 9000903)), 0);
  perform public.plant_users_upsert(p, acc, three);  -- the hourly sync lists the deleted plant again
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claims', '', true);
  o := public.billing_charge_open(p, 'home', 'monthly');
  perform public.billing_charge_paid(o->>'reference', v_card);
  perform pg_temp.eq('buy again: the same two run, the third stays locked',
    (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = p),
    '9000901:true,9000902:false,9000903:false');
  perform pg_temp.eq('buy again: the change date did not move',
    (select changed_on = t - 89 from private.plant_change where user_id = p), true);

  -- remove the login and link it again: no fresh pick
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform public.api_link_remove(acc);
  perform pg_temp.eq('remove: the ticks stay', (select count(*)::int from private.plant_picks where user_id = p and held), 2);
  perform set_config('request.jwt.claims', '', true);
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values (acc, p, 'p@login.test');
  perform public.plant_users_upsert(p, acc, three);
  perform pg_temp.eq('link again: the ticked two start on their own, the third is locked',
    (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = p),
    '9000901:true,9000902:false,9000903:false');
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform pg_temp.raises('link again: no fresh pick', 'select public.api_plant_pick(array[9000901])', 'no room');

  -- a plant gone from the login's list, twice 50 minutes apart: not read, but it keeps its place
  perform public.plant_users_upsert(p, acc, three - 2);
  perform pg_temp.eq('gone: one miss changes nothing', (select paused or share_gone_at is not null from public.plant_users where user_id = p and plant_id = 9000903), false);
  update public.plant_users set share_missing_at = now() - interval '1 hour' where user_id = p and plant_id = 9000903;
  perform public.plant_users_upsert(p, acc, three - 2);
  perform pg_temp.eq('gone: marked, still on screen, its tick stays',
    (select not paused and share_gone_at is not null from public.plant_users where user_id = p and plant_id = 9000903)::text || ' ' ||
    (select count(*) from private.plant_picks where user_id = p and plant_id = 9000903 and held), 'true 1');
  perform pg_temp.eq('gone: nothing reads it', (select count(*)::int from public.poll_jobs(0, 1) where plant_id = 9000903), 0);
  perform pg_temp.eq('gone: its owner is told once, with the login',
    (select count(*) || ' ' || max(data->>'login') || ' ' || max(data->'plants'->>0) from public.email_queue where user_id = p and kind = 'plant_off_login'),
    '1 p@login.test Three');
  perform pg_temp.raises('gone: it still takes its place', 'select public.api_plant_pick(array[9000901])', 'no room');
  perform public.plant_users_upsert(p, acc, three);
  perform pg_temp.eq('gone: back in the list it is read again',
    (select not paused and share_gone_at is null and share_missing_at is null from public.plant_users where user_id = p and plant_id = 9000903), true);

  -- 90 days on, the change opens
  update private.plant_change set changed_on = t - 90 where user_id = p;
  perform pg_temp.eq('change: open again after 90 days', public.api_plant_picks()->>'change_on', null::text);
  perform public.api_plant_change(9000902, 9000901);
  perform pg_temp.eq('change: the second one, 90 days on', (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = p),
    '9000901:false,9000902:true,9000903:false');

  -- a failed payment: no change and no new tick until it is paid (0198, SOLAR-546).
  -- Family, so a place is open; the change is open too. A paid account is the tests above.
  perform set_config('request.jwt.claims', '', true);
  update private.billing set plan = 'family', state = 'past_due', past_due_since = t where user_id = p;
  update private.plant_change set changed_on = t - 90 where user_id = p;
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on)
  values ('psh_p9', p, 'renewal', 'family', 'monthly', 199, 'failed', t, t);
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform pg_temp.raises('past due: a change is refused', 'select public.api_plant_change(9000901, 9000902)', 'pay the failed payment first');
  perform pg_temp.raises('past due: a tick is refused', 'select public.api_plant_pick(array[9000902])', 'pay the failed payment first');
  perform pg_temp.eq('past due: nothing moved, the change is not used',
    (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = p) || ' ' ||
    (select changed_on = t - 90 from private.plant_change where user_id = p), '9000901:false,9000902:true,9000903:false true');
  perform set_config('request.jwt.claims', '', true);
  o := public.billing_settle_open(p);
  perform public.billing_charge_paid(o->>'reference', v_card);
  perform pg_temp.eq('paid: active again', (select state from private.billing where user_id = p), 'active');
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform public.api_plant_change(9000901, 9000902);
  perform public.api_plant_pick(array[9000901]);
  perform pg_temp.eq('paid: the change and the tick both work',
    (select string_agg(plant_id || ':' || paused, ',' order by plant_id) from public.plant_users where user_id = p),
    '9000901:false,9000902:false,9000903:false');
  perform set_config('request.jwt.claims', '', true);

  -- a failed payment again, Family with 2 places open: a new login with one plant and a
  -- share claim link locked, with no tick (0200, SOLAR-548)
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username) values
    ('00000000-0000-0000-0000-0000000009b3', p, 'p2@login.test'), ('00000000-0000-0000-0000-0000000009b4', p, 'p3@login.test');
  sh := coalesce((select id from private.sunsynk_accounts where kind = 'share'), gen_random_uuid());
  insert into private.sunsynk_accounts (id, user_id, sunsynk_username, kind) values (sh, q, 'share@login.test', 'share')
  on conflict (id) do nothing;
  update private.billing set state = 'past_due', past_due_since = t where user_id = p;
  insert into private.billing_charges (reference, user_id, kind, plan, period, amount, status, due_on, created_on)
  values ('psh_p10', p, 'renewal', 'family', 'monthly', 199, 'failed', t, t);
  perform public.plant_users_upsert(p, '00000000-0000-0000-0000-0000000009b3', '[{"plant_id": 9000904, "plant_name": "Four"}]');
  perform pg_temp.eq('past due: a new login''s one plant links locked',
    (select paused from public.plant_users where user_id = p and plant_id = 9000904), true);
  perform pg_temp.eq('past due: a share claim links locked', public.share_claim(p, sh, 9000905, 'Five'), 'claimed_paused');
  perform pg_temp.eq('past due: neither has a tick',
    (select count(*)::int from private.plant_picks where user_id = p and plant_id in (9000904, 9000905)), 0);
  perform pg_temp.eq('past due: neither is read', (select count(*)::int from public.poll_jobs(0, 1) where plant_id in (9000904, 9000905)), 0);
  o := public.billing_settle_open(p);
  perform public.billing_charge_paid(o->>'reference', v_card);
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('paid: both wait for the owner''s tick, and can start',
    (select count(*)::int from public.api_link_status() s, jsonb_array_elements(s.plants) x
      where (x->>'can_start')::boolean and (x->>'plant_id')::bigint in (9000904, 9000905)), 2);
  perform set_config('request.jwt.claims', '', true);
  perform public.plant_users_upsert(p, '00000000-0000-0000-0000-0000000009b4', '[{"plant_id": 9000906, "plant_name": "Six"}]');
  perform pg_temp.eq('paid: a new login''s one plant runs at once',
    (select paused from public.plant_users where user_id = p and plant_id = 9000906), false);
  perform pg_temp.eq('paid: a share claim runs at once', public.share_claim(p, sh, 9000907, 'Seven'), 'claimed');

  -- a login with one plant and an open place starts it with no pick
  perform public.plant_users_upsert(q, '00000000-0000-0000-0000-0000000009b2', '[{"plant_id": 9000911, "plant_name": "Only"}]');
  perform pg_temp.eq('one plant: runs at once', (select paused from public.plant_users where user_id = q and plant_id = 9000911), false);
end $$;
select pg_temp.eq('stop is gone',  (select count(*)::int from pg_proc where proname = 'api_plant_stop'), 0);
select pg_temp.eq('start is gone', (select count(*)::int from pg_proc where proname = 'api_plant_start'), 0);
select pg_temp.eq('pick is for signed-in users',   has_function_privilege('anon', 'public.api_plant_pick(bigint[])', 'execute'), false);
select pg_temp.eq('change is for signed-in users', has_function_privilege('anon', 'public.api_plant_change(bigint, bigint)', 'execute'), false);
select pg_temp.eq('ticks table closed', has_table_privilege('authenticated', 'private.plant_picks', 'select'), false);

-- ---------------------------------------------------------------------------
-- No Free plan after the free week (0203 to 0206, SOLAR-552). Links go through
-- plant_users_upsert, as link-sunsynk and the hourly sync call it.
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) select ('00000000-0000-0000-0000-000000000a0' || i)::uuid, 'w' || i || '@t.test' from generate_series(1, 8) i;
insert into private.sunsynk_accounts (id, user_id, sunsynk_username)
  select ('00000000-0000-0000-0000-00000000ac0' || i)::uuid, ('00000000-0000-0000-0000-000000000a0' || i)::uuid, 'w' || i || '@login.test' from generate_series(1, 8) i;
create function pg_temp.rows(variadic ids int[]) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('plant_id', 9007700 + x, 'plant_name', 'P' || x) order by x) from unnest(ids) x $$;
-- what the signed-in user gets from a statement; 'REFUSED: ...' when it raises
create function pg_temp.as_user(u uuid, stmt text) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  begin execute stmt into r; exception when others then r := 'REFUSED: ' || sqlerrm; end;
  perform set_config('request.jwt.claims', '', true);
  return r;
end $$;
create function pg_temp.week_ends(u uuid) returns timestamptz language sql as $$
  select (pg_temp.as_user(u, 'select public.api_me()->>''freeWeekEndsAt'''))::timestamptz $$;
-- the account's week and its plants' weeks, d days earlier
create function pg_temp.days_on(u uuid, d numeric) returns void language sql as $$
  update private.plant_week set started_at = started_at - d * interval '1 day'
   where plant_id in (select plant_id from public.plant_users where user_id = u);
  update private.free_week_logins set started_at = started_at - d * interval '1 day', written_at = written_at - d * interval '1 day',
         over_at = over_at - d * interval '1 day' where user_id = u $$;
do $$
declare
  w1 uuid := '00000000-0000-0000-0000-000000000a01'; w2 uuid := '00000000-0000-0000-0000-000000000a02';
  w3 uuid := '00000000-0000-0000-0000-000000000a03'; w4 uuid := '00000000-0000-0000-0000-000000000a04';
  w5 uuid := '00000000-0000-0000-0000-000000000a05'; w6 uuid := '00000000-0000-0000-0000-000000000a06';
  a1 uuid := '00000000-0000-0000-0000-00000000ac01'; a2 uuid := '00000000-0000-0000-0000-00000000ac02';
  a3 uuid := '00000000-0000-0000-0000-00000000ac03'; a4 uuid := '00000000-0000-0000-0000-00000000ac04';
  a5 uuid := '00000000-0000-0000-0000-00000000ac05'; a6 uuid := '00000000-0000-0000-0000-00000000ac06';
  t date := private.billing_today();
  tok uuid;
begin
  -- a login with 3 plants: all run, each starts its week, the account has 7 days
  perform public.plant_users_upsert(w1, a1, pg_temp.rows(1, 2, 3));
  insert into public.plant_config (plant_id) select 9007700 + x from generate_series(1, 3) x on conflict do nothing;
  insert into public.agg_minute (plant_id, ts) select 9007701, extract(epoch from now() - h * interval '1 hour')::bigint from unnest(array[1, 30, 240]) h;
  perform pg_temp.eq('3 plants: all run', (select count(*)::int from public.plant_users where user_id = w1 and not paused), 3);
  perform pg_temp.eq('3 plants: 3 plant weeks', (select count(*)::int from private.plant_week where plant_id between 9007701 and 9007703), 3);
  perform pg_temp.eq('3 plants: the account has 7 days', pg_temp.week_ends(w1) between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour', true);
  perform pg_temp.eq('in the week: no wall', pg_temp.as_user(w1, 'select public.api_me()->>''wall'''), null);
  perform pg_temp.eq('in the week: reads its plants', pg_temp.as_user(w1, 'select jsonb_array_length(public.api_me()->''plants'')'), '3');
  perform pg_temp.eq('in the week: polled', (select count(*)::int from public.live_plants() x where x between 9007701 and 9007703), 3);

  -- one login with no plan
  perform pg_temp.eq('one login: a second is refused', public.link_login_allowed(w1, 'other@login.test'), false);
  perform pg_temp.eq('one login: the same one again is fine', public.link_login_allowed(w1, 'w1@login.test'), true);
  perform pg_temp.eq('one login: a paid account may add more', public.link_login_allowed('00000000-0000-0000-0000-0000000000a1', 'other@login.test'), true);
  perform pg_temp.raises('one login: account_upsert refuses', format('select public.account_upsert(%L, ''other@login.test'', ''x'', 0)', w1), 'one login');

  -- a login with 6 plants: none runs and no week starts until the owner ticks 5
  perform public.plant_users_upsert(w2, a2, pg_temp.rows(11, 12, 13, 14, 15, 16));
  perform pg_temp.eq('6 plants: all locked', (select count(*)::int from public.plant_users where user_id = w2 and paused), 6);
  perform pg_temp.eq('6 plants: no plant week', (select count(*)::int from private.plant_week where plant_id between 9007711 and 9007716), 0);
  perform pg_temp.eq('6 plants: no account week', (select count(*)::int from private.free_week_logins where user_id = w2), 0);
  perform pg_temp.eq('6 plants: a 6th tick is refused',
    pg_temp.as_user(w2, 'select public.api_plant_pick(array[9007711, 9007712, 9007713, 9007714, 9007715, 9007716])::text'), 'REFUSED: no room');
  perform pg_temp.as_user(w2, 'select public.api_plant_pick(array[9007711, 9007712, 9007713, 9007714, 9007715])::text');
  perform pg_temp.eq('5 ticked: 5 run', (select count(*)::int from public.plant_users where user_id = w2 and not paused), 5);
  perform pg_temp.eq('5 ticked: their weeks start', (select count(*)::int from private.plant_week where plant_id between 9007711 and 9007715), 5);
  perform pg_temp.eq('the plant not ticked keeps its week', (select count(*)::int from private.plant_week where plant_id = 9007716), 0);
  perform pg_temp.eq('5 ticked: the account week starts', pg_temp.week_ends(w2) > now() + interval '6 days', true);
  perform pg_temp.eq('the ticks are fixed', pg_temp.as_user(w2, 'select public.api_plant_change(9007711, 9007716)::text'), 'REFUSED: no change without a plan');

  -- day 8: the pay screen, nothing read, not polled, no alert or report
  perform pg_temp.days_on(w1, 8);
  perform pg_temp.eq('day 8: wall, with the plants ticked', pg_temp.as_user(w1, 'select public.api_me()->''wall''->>''plants'''), '3');
  perform pg_temp.eq('day 8: wall says the free week', pg_temp.as_user(w1, 'select public.api_me()->''wall''->>''paid'''), 'false');
  perform pg_temp.eq('day 8: history kept until day 37',
    (pg_temp.as_user(w1, 'select public.api_me()->''wall''->>''deleteAt'''))::timestamptz between now() + interval '28 days 23 hours' and now() + interval '29 days 1 hour', true);
  perform pg_temp.eq('day 8: no plant to read', pg_temp.as_user(w1, 'select jsonb_array_length(public.api_me()->''plants'')'), '0');
  perform pg_temp.eq('day 8: export refused', pg_temp.as_user(w1, format('select public.api_export(%L, %L, 9007701)', t - 20, t)), 'REFUSED: plant 9007701 is not linked to this user');
  perform pg_temp.eq('day 8: not polled', (select count(*)::int from public.live_plants() x where x between 9007701 and 9007703), 0);
  insert into public.email_queue (user_id, plant_id, kind, key, data) values
    (w1, 9007701, 'grid_down', 'test:w1-alert', '{}'), (w1, 9007701, 'report_week', 'test:w1-report', '{}'),
    (w1, 9007701, 'report_week', 'test:w1-last', '{"freeWeekEnds": true}');
  perform pg_temp.eq('day 8: no alert, no report, but the week''s last report',
    (select array_agg(key order by key) from public.email_queue where key like 'test:w1-%'), array['test:w1-last']);
  perform private.unpaid_delete();
  perform pg_temp.eq('day 8: readings kept', (select count(*)::int from public.agg_minute where plant_id = 9007701), 3);

  -- a second account on a plant that had its week: no week
  perform public.plant_users_upsert(w3, a3, pg_temp.rows(1));
  perform pg_temp.eq('used plant: the plant week did not move', (select started_at < now() - interval '7 days' from private.plant_week where plant_id = 9007701), true);
  perform pg_temp.eq('used plant: no week for the new account', pg_temp.week_ends(w3) <= now(), true);
  perform pg_temp.eq('used plant: the new account is at the pay screen', pg_temp.as_user(w3, 'select public.api_me()->''wall'' is not null'), 'true');
  perform pg_temp.eq('used plant: nothing read', pg_temp.as_user(w3, 'select count(*) from public.my_plant_ids()'), '0');
  perform pg_temp.eq('used plant: still not polled', (select count(*)::int from public.live_plants() x where x = 9007701), 0);
  -- the plant's history is loaded: its email is queued at the link, and skipped when it is sent (0216, SOLAR-572)
  perform pg_temp.eq('used plant: history email queued', (select count(*)::int from public.email_queue where kind = 'history' and user_id = w3), 1);
  perform pg_temp.eq('used plant: history email not sent', (select count(*)::int from public.email_claim(100000, true) c where c.kind = 'history' and c.user_id = w3), 0);

  -- a join on day 3 has the 4 days left, and reads
  perform public.plant_users_upsert(w4, a4, pg_temp.rows(21));
  insert into public.plant_config (plant_id) values (9007721) on conflict do nothing;
  perform pg_temp.days_on(w4, 3);
  perform public.plant_users_upsert(w5, a5, pg_temp.rows(21));
  perform pg_temp.eq('join on day 3: 4 days left', pg_temp.week_ends(w5) between now() + interval '3 days 23 hours' and now() + interval '4 days 1 hour', true);
  perform pg_temp.eq('join on day 3: reads the plant', pg_temp.as_user(w5, 'select string_agg(x::text, '','') from public.my_plant_ids() x'), '9007721');
  perform pg_temp.eq('join on day 3: history email sent', (select count(*)::int from public.email_claim(100000, true) c where c.kind = 'history' and c.user_id = w5), 1);
  -- day 2 setup email: to the account that reads its plant, not to the one at the pay screen (0216)
  update public.plant_users set linked_at = now() - interval '2 days 1 hour' where user_id in (w3, w5);
  perform private.free_week_mail();
  perform pg_temp.eq('setup email: only where the plant is read',
    (select array_agg(user_id order by user_id) from public.email_queue where kind = 'free_week_setup' and user_id in (w3, w5)), array[w5]);

  -- the two emails: 14 and 27 days after the week ended, once each, with an unsubscribe
  perform pg_temp.days_on(w1, 13.1);   -- day 21
  perform private.free_week_mail(); perform private.free_week_mail();
  perform pg_temp.eq('day 21: the reminder, once', (select array_agg(kind) from public.email_queue where user_id = w1 and kind like 'unpaid%'), array['unpaid_reminder']);
  perform pg_temp.eq('day 21: it carries the delete date', (select to_timestamp((data->>'deleteAt')::bigint) between now() + interval '15 days' and now() + interval '17 days'
    from public.email_queue where user_id = w1 and kind = 'unpaid_reminder'), true);
  perform pg_temp.days_on(w1, 13);     -- day 34
  perform private.free_week_mail();
  perform pg_temp.eq('day 34: the last one', (select count(*)::int from public.email_queue where user_id = w1 and kind = 'unpaid_last'), 1);
  perform pg_temp.eq('the reminders have a switch', private.email_switch('unpaid_last'), 'reminders');
  tok := public.email_unsub_token(w1);
  perform pg_temp.eq('unsubscribe: the token turns them off', public.email_unsubscribe(tok, 'reminders'), true);
  perform pg_temp.eq('unsubscribe: not wanted after', public.email_wanted(w1, 'reminders'), false);
  perform pg_temp.eq('unsubscribe: alerts stay as they were', public.email_wanted(w1, 'grid'), true);
  -- day 37: gone
  perform private.unpaid_delete();
  perform pg_temp.eq('day 34: readings still there', (select count(*)::int from public.agg_minute where plant_id = 9007701), 3);
  perform pg_temp.eq('day 34: no email about a delete yet', (select count(*)::int from public.email_queue where kind = 'unpaid_deleted' and user_id in (w1, w3)), 0);
  perform pg_temp.days_on(w1, 3);
  perform pg_temp.days_on(w3, 30);     -- the second account on plant 1 is past its 30 days too
  perform private.unpaid_delete();
  perform pg_temp.eq('day 37: readings gone', (select count(*)::int from public.agg_minute where plant_id = 9007701), 0);
  -- the email after the delete (0207): once per account, with the plants ticked, under the reminders switch
  perform private.unpaid_delete();
  perform pg_temp.eq('day 37: the email, once, and none for the account that never had a week (0209)',
    (select array_agg(user_id order by user_id) from public.email_queue where kind = 'unpaid_deleted' and user_id in (w1, w3)), array[w1]);
  perform pg_temp.eq('day 37: it carries the plants ticked', (select data from public.email_queue where kind = 'unpaid_deleted' and user_id = w1),
    '{"plants": 3, "paid": false}'::jsonb);
  perform pg_temp.eq('day 37: it has the reminders switch', private.email_switch('unpaid_deleted'), 'reminders');
  perform pg_temp.eq('day 37: not sent to the account that unsubscribed',
    (select count(*)::int from public.email_claim(100000, true) c where c.kind = 'unpaid_deleted' and c.user_id = w1), 0);
  perform pg_temp.eq('day 5 and day 7 carry the plants ticked', (select (data->>'plants')::int from public.email_queue
    where user_id = '00000000-0000-0000-0000-000000000071' and kind = 'free_week_soon'), 1);
  -- paying: read again, the 60 days booked
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values (w1, 'family', 'monthly', 1, t + 30);
  perform pg_temp.eq('paid: no wall', pg_temp.as_user(w1, 'select public.api_me()->>''wall'''), null);
  perform pg_temp.eq('paid: polled again', (select count(*)::int from public.live_plants() x where x between 9007701 and 9007703), 3);
  perform pg_temp.eq('paid: 60 days booked', (select count(*)::int from public.plant_config
    where plant_id between 9007701 and 9007703 and backfill_next = (now() at time zone 'Africa/Johannesburg')::date - 60), 3);
  perform pg_temp.eq('paid: the other account on the plant still reads nothing', pg_temp.as_user(w3, 'select count(*) from public.my_plant_ids()'), '0');

  -- a first plan with fewer places than plants running: the ticked ones stay (0205)
  perform pg_temp.eq('start keep: another account''s plant refused',
    pg_temp.as_user(w2, 'select public.api_billing_start_keep(array[9007701])'), 'REFUSED: a plant is not running for this user');
  perform pg_temp.as_user(w2, 'select public.api_billing_start_keep(array[9007714, 9007715])');
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values (w2, 'home', 'monthly', 1, t + 30)
  on conflict (user_id) do update set plan = 'home', period = 'monthly', billing_day = 1, next_billing_date = t + 30;
  perform pg_temp.eq('start keep: the two ticked run on Home', (select string_agg(plant_id::text, ',' order by plant_id) from public.plant_users where user_id = w2 and not paused), '9007714,9007715');
  perform pg_temp.eq('start keep: the list is cleared', (select next_keep from private.billing where user_id = w2), '{}'::bigint[]);
  perform pg_temp.eq('start keep: not on a plan', pg_temp.as_user(w2, 'select public.api_billing_start_keep(array[9007714])'), 'REFUSED: nothing to pick');
  -- an account with a plan: its readings stay, so no email about a delete
  perform pg_temp.days_on(w2, 60);
  insert into public.agg_minute (plant_id, ts) values (9007714, extract(epoch from now() - interval '5 days')::bigint);
  perform private.unpaid_delete();
  perform pg_temp.eq('paid: readings kept', (select count(*)::int from public.agg_minute where plant_id = 9007714), 1);
  perform pg_temp.eq('paid: no email about a delete', (select count(*)::int from public.email_queue where kind = 'unpaid_deleted' and user_id in (w1, w2)), 1);
  perform pg_temp.eq('one login: capitals do not make a second', public.link_login_allowed(w1, 'W1@Login.Test'), true);

  -- a failed card: 8 days, then the pay screen at once and nothing read; the history goes 30 days later (SOLAR-564)
  perform public.plant_users_upsert(w6, a6, pg_temp.rows(31));
  perform pg_temp.days_on(w6, 60);
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date, state, past_due_since) values (w6, 'home', 'monthly', 1, t, 'past_due', t - 8);
  insert into public.agg_minute (plant_id, ts) values (9007731, extract(epoch from now() - interval '5 days')::bigint);
  perform private.billing_to_free(w6, t);
  perform pg_temp.eq('failed card: nothing read', pg_temp.as_user(w6, 'select string_agg(x::text, '','') from public.my_plant_ids() x'), null);
  perform pg_temp.eq('failed card: the pay screen at once', pg_temp.as_user(w6, 'select public.api_me()->''wall'' is not null'), 'true');
  perform pg_temp.eq('failed card: not polled', (select count(*)::int from public.live_plants() x where x = 9007731), 0);
  perform private.unpaid_delete();
  perform pg_temp.eq('failed card: kept in the 30 days', (select count(*)::int from public.agg_minute where plant_id = 9007731), 1);
  update private.billing set ended_at = now() - interval '31 days' where user_id = w6;
  perform pg_temp.eq('failed card: the pay screen after', pg_temp.as_user(w6, 'select public.api_me()->''wall''->>''paid'''), 'false');
  perform private.unpaid_delete();
  perform pg_temp.eq('failed card: gone after', (select count(*)::int from public.agg_minute where plant_id = 9007731), 0);
  -- no free-week row (a login of more than 5 plants): the pay screen from the end of its paid time (SOLAR-564)
  delete from private.free_week_logins where user_id = w6;
  perform pg_temp.eq('no week row: the pay screen', pg_temp.as_user(w6, 'select public.api_me()->''wall'' is not null'), 'true');
  perform pg_temp.eq('no week row: deleted 30 days after', (select private.unpaid_since(w6) < now() - interval '30 days'), true);
  -- an account with no plan on a plant another account pays for: the reminder goes, 'deleted in 3 days' does not (0216)
  insert into private.billing (user_id, plan, period, billing_day, next_billing_date) values (w4, 'home', 'monthly', 1, t + 30);
  perform pg_temp.days_on(w5, 18.5);
  perform private.free_week_mail();
  perform pg_temp.eq('payer''s plant: the day-14 reminder goes', (select count(*)::int from public.email_queue where user_id = w5 and kind = 'unpaid_reminder'), 1);
  perform pg_temp.days_on(w5, 13);
  perform private.free_week_mail();
  perform pg_temp.eq('payer''s plant: no deleted-in-3-days email', (select count(*)::int from public.email_queue where user_id = w5 and kind = 'unpaid_last'), 0);
  perform pg_temp.eq('payer''s plant: its readings are not deleted', (select 9007721 in (select public.live_plants())), true);
end $$;
select pg_temp.eq('plant week closed to users', has_table_privilege('authenticated', 'private.plant_week', 'select'), false);
select pg_temp.eq('readable plants not for anon', has_function_privilege('anon', 'public.my_plant_ids()', 'execute'), false);
select pg_temp.eq('the 24-hour rule is gone', (select count(*)::int from pg_policies where policyname like '%\_free\_read'), 0);

-- A paid account from before 0199 has no free-week row (0200, SOLAR-548). m = Home, its
-- plant linked the old way. 0200 gives it a row 15 days back; then it drops to Free.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000e548', 'm@t.test');
insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
  values ('00000000-0000-0000-0000-00000000e548', 'home', 'monthly', 1, current_date + 20);
insert into private.plant_picks (user_id, plant_id, plant_name) values ('00000000-0000-0000-0000-00000000e548', 9000961, 'M');
insert into public.plant_users (plant_id, user_id) values (9000961, '00000000-0000-0000-0000-00000000e548');
do $$
declare m uuid := '00000000-0000-0000-0000-00000000e548';
begin
  perform pg_temp.eq('old paid account: no row', (select count(*)::int from private.free_week_logins where user_id = m), 0);
  -- 0200's insert
  insert into private.free_week_logins (sunsynk_username, user_id, started_at)
  select '', pu.user_id, now() - interval '15 days' from public.plant_users pu group by pu.user_id
  on conflict (user_id) do nothing;
  perform pg_temp.eq('0200: every account with a plant has a row',
    (select count(*)::int from public.plant_users pu
      where not exists (select 1 from private.free_week_logins f where f.user_id = pu.user_id)), 0);
  perform pg_temp.eq('0200: a row that was there keeps its date',
    (select started_at > now() - interval '6 days' from private.free_week_logins where user_id = '00000000-0000-0000-0000-000000000071'), true);
  insert into public.email_queue (user_id, plant_id, kind, key, data) values (m, 9000961, 'report_week', 'test:m-paid-report', '{}');
  perform pg_temp.eq('old paid account, still paid: reports go', (select count(*)::int from public.email_queue where key = 'test:m-paid-report'), 1);
  update private.billing set plan = 'free', period = null, billing_day = null, next_billing_date = null where user_id = m;
  insert into public.email_queue (user_id, plant_id, kind, key, data) values
    (m, 9000961, 'report_week', 'test:m-week', '{}'), (m, 9000961, 'report_month', 'test:m-month', '{}'),
    (m, 9000961, 'report_year', 'test:m-year', '{}');
  perform pg_temp.eq('old paid account on Free: no reports',
    (select count(*)::int from public.email_queue where key in ('test:m-week', 'test:m-month', 'test:m-year')), 0);
  perform pg_temp.eq('old paid account on Free: no free week', pg_temp.week_ends(m) < now() - interval '7 days', true);
  perform private.free_week_mail();
  perform pg_temp.eq('old paid account on Free: no free-week email',
    (select count(*)::int from public.email_queue where user_id = m and kind in ('free_week_soon', 'report_week')
       and key <> 'test:m-paid-report'), 0);
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  perform pg_temp.eq('old paid account on Free: no free-week notice',
    (select count(*)::int from jsonb_array_elements(private.billing_notices()) n where n->>'kind' in ('free_week_soon', 'free_week_ended')), 0);
  perform set_config('request.jwt.claims', '', true);
end $$;

select pg_temp.eq('keep set is for signed-in users', has_function_privilege('anon', 'public.api_billing_keep_set(bigint[])', 'execute'), false);

-- Two stores with a cap (0201, SOLAR-549). n = free week ends in a day: one notice.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000e549', 'cap549@t.test');
insert into private.free_week_logins (sunsynk_username, user_id, started_at)
  values ('n-549', '00000000-0000-0000-0000-00000000e549', now() - interval '6 days');
do $$
declare n uuid := '00000000-0000-0000-0000-00000000e549'; real text; small jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', n, 'role', 'authenticated')::text, true);
  real := public.api_notifications()->'pinned'->0->>'key';
  perform pg_temp.eq('notice read: the account has one notice', jsonb_array_length(public.api_notifications()->'pinned'), 1);
  perform public.api_notices_read(array['made-up', 'free_week_ended:' || md5('x'), repeat('k', 1000)]);
  perform pg_temp.eq('notice read: a made-up key is not stored', (select count(*)::int from private.notice_reads where user_id = n), 0);
  perform public.api_notices_read((select array_agg('junk-' || g) from generate_series(1, 20000) g));
  perform pg_temp.eq('notice read: 20,000 keys store none', (select count(*)::int from private.notice_reads where user_id = n), 0);
  perform public.api_notices_read((select array_agg('junk-' || g) || real from generate_series(1, 20000) g));
  perform pg_temp.eq('notice read: 20,000 keys and the real one store the real one',
    (select array_agg(key) from private.notice_reads where user_id = n), array[real]);
  perform pg_temp.eq('notice read: the notice reads as read', (public.api_notifications()->'pinned'->0->>'read')::boolean, true);
  delete from private.notice_reads where user_id = n;
  perform public.api_notices_read(array[real]);
  perform pg_temp.eq('notice read: a real key is stored', (select count(*)::int from private.notice_reads where user_id = n), 1);
  delete from private.notice_reads where user_id = n;
  perform public.api_notifications_read(null);
  perform pg_temp.eq('notice read: Mark all read stores it', (select count(*)::int from private.notice_reads where user_id = n), 1);

  -- prefs: the app's largest write is firstSteps, about 100 bytes a plant
  small := jsonb_build_object('lastPlant', 9000961, 'freeWeekOverSeen', true, 'firstSteps',
    (select jsonb_object_agg(9000000 + g, jsonb_build_object('at', now(), 'done', true, 'hidden', true, 'reserve', true))
       from generate_series(1, 20) g));
  perform pg_temp.eq('prefs: a normal write passes', public.api_prefs_set(small) ? 'firstSteps', true);
  perform pg_temp.eq('prefs: 20 plants of steps stay under 3,000 bytes',
    (select octet_length(prefs::text) < 3000 from public.profiles where user_id = n), true);
  perform pg_temp.raises('prefs: 5 MB is refused',
    format('select public.api_prefs_set(jsonb_build_object(''x'', repeat(''a'', 5000000)))'), 'profiles_prefs_size');
  perform pg_temp.raises('prefs: 5 MB by a table write is refused',
    format('update public.profiles set prefs = jsonb_build_object(''x'', repeat(''a'', 5000000)) where user_id = %L', n), 'profiles_prefs_size');
  perform pg_temp.raises('prefs: 21,000 bytes is refused',
    format('select public.api_prefs_set(jsonb_build_object(''x'', repeat(''a'', 21000)))'), 'profiles_prefs_size');
  perform pg_temp.eq('prefs: 17,000 bytes more passes', public.api_prefs_set(jsonb_build_object('x', repeat('a', 17000))) ? 'x', true);
  perform pg_temp.eq('prefs: the row keeps its last good value',
    (select prefs ? 'lastPlant' from public.profiles where user_id = n), true);
  perform set_config('request.jwt.claims', '', true);
  -- rows from before the rule: each one fits, and saves again
  perform pg_temp.eq('prefs: no row in the database is over the limit',
    (select count(*)::int from public.profiles where octet_length(prefs::text) > 20000), 0);
  update public.profiles set prefs = prefs || '{"lastPlant": 1}' where user_id <> n;
end $$;

\set QUIET off
do $$ begin
  if exists (select 1 from pg_temp.fails) then
    raise exception E'billing tests failed:\n%', (select string_agg(what, E'\n' order by n) from pg_temp.fails);
  end if;
end $$;
select 'PASS' as billing_tests;
rollback;
