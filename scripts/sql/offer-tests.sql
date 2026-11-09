-- Offer tests (SOLAR-330, 0145). Local database at the latest migration; everything rolls back.
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/sql/offer-tests.sql
-- Exit code decides: any wrong case raises.
\set QUIET on
begin;
create or replace function private.billing_today() returns date language sql stable as $$ select current_setting('t.today')::date $$;
select set_config('t.today', '2026-12-01', true) \g /dev/null
-- only the offers made here
update private.offers set joins_until = date '2000-01-01';

create temp table fails (n serial, what text);
create function pg_temp.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is distinct from want then insert into pg_temp.fails (what) values (format('%s: got %s, want %s', label, got, want)); end if;
end $$;
-- A Free account pays a start; returns the charge's amount.
create function pg_temp.start(u uuid, plan text, period text) returns int language plpgsql as $$
declare q jsonb;
begin
  q := public.billing_charge_open(u, plan, period);
  perform public.billing_charge_paid(q->>'reference', '{"authorization_code":"A","reusable":true}', true);
  return (q->>'amount')::int;
end $$;
create function pg_temp.uid(n int) returns uuid language sql as $$ select ('00000000-0000-0000-0000-' || lpad(to_hex(n), 12, '0'))::uuid $$;

insert into auth.users (id, email) select pg_temp.uid(n), 'o' || n || '@t.test' from generate_series(9001, 9012) n;

-- Two places only, for life.
insert into private.offers (id, home_monthly, home_yearly, family_monthly, family_yearly, extra_monthly, extra_yearly, opens_on, max_payers)
values ('t_launch', 49, 490, 89, 890, 29, 290, '2026-11-01', 2);

do $$
declare u1 uuid := pg_temp.uid(9001); u2 uuid := pg_temp.uid(9002); u3 uuid := pg_temp.uid(9003);
begin
  perform pg_temp.eq('first payer R49', pg_temp.start(u1, 'home', 'monthly'), 49);
  perform pg_temp.eq('second payer yearly R890', pg_temp.start(u2, 'family', 'yearly'), 890);
  perform pg_temp.eq('third payer list R99', pg_temp.start(u3, 'home', 'monthly'), 99);
  perform pg_temp.eq('u1 holds', (select offer_id from private.billing where user_id = u1), 't_launch');
  perform pg_temp.eq('u3 holds none', (select offer_id from private.billing where user_id = u3), null::text);
  perform pg_temp.eq('u1 renews at R49', public.billing_amount_due(u1), 49);
  perform pg_temp.eq('u3 renews at R99', public.billing_amount_due(u3), 99);
  -- upgrade at the offer: Family R89 from the next date
  perform pg_temp.eq('u1 upgrade next at offer', (public.billing_upgrade_quote(u1, 'family', 0)->>'nextCharge')::int, 89);
  perform pg_temp.eq('u1 upgrade list shown', (public.billing_upgrade_quote(u1, 'family', 0)->>'listCharge')::int, 199);
  -- an extra plant past the 3rd: R29
  perform pg_temp.eq('u2 extra plant yearly', public.billing_amount('family', 'yearly', 1, 't_launch'), 890 + 290);

  -- cancel booked, then undone before the date: price kept
  perform public.billing_book_change(u1, 'free', null, null);
  perform public.billing_book_change(u1, 'home', null, null);
  perform pg_temp.eq('undo keeps offer', (select offer_id from private.billing where user_id = u1), 't_launch');
  perform pg_temp.eq('undo renews R49', public.billing_amount_due(u1), 49);

  -- cancel reaches its date: back to Free, offer gone, place not reopened
  perform public.billing_book_change(u1, 'free', null, null);
  perform set_config('t.today', '2027-01-01', true);
  perform public.billing_run('2027-01-01');
  perform pg_temp.eq('u1 on Free', (select plan from private.billing where user_id = u1), 'free');
  perform pg_temp.eq('u1 offer gone', (select offer_id from private.billing where user_id = u1), null::text);
  perform pg_temp.eq('u1 returns at list', pg_temp.start(u1, 'home', 'monthly'), 99);
  perform pg_temp.eq('place not reopened', (select count(*)::int from private.offer_members where offer_id = 't_launch'), 2);
  perform pg_temp.eq('new account at list', pg_temp.start(pg_temp.uid(9004), 'home', 'monthly'), 99);
end $$;

-- A card page opened before the last place went: that payment keeps its price, the renewals don't.
select set_config('t.today', '2026-12-01', true) \g /dev/null
insert into private.offers (id, home_monthly, home_yearly, family_monthly, family_yearly, extra_monthly, extra_yearly, opens_on, max_payers)
values ('t_one', 39, 390, 79, 790, 19, 190, '2026-11-15', 1);
do $$
declare u5 uuid := pg_temp.uid(9005); u6 uuid := pg_temp.uid(9006); q5 jsonb; q6 jsonb;
begin
  q5 := public.billing_charge_open(u5, 'home', 'monthly');
  q6 := public.billing_charge_open(u6, 'home', 'monthly');
  perform pg_temp.eq('both quoted R39', (q5->>'amount')::int + (q6->>'amount')::int, 78);
  perform public.billing_charge_paid(q5->>'reference', '{"authorization_code":"A","reusable":true}', true);
  perform pg_temp.eq('late payer applied', public.billing_charge_paid(q6->>'reference', '{"authorization_code":"B","reusable":true}', true)->>'applied', null);
  perform pg_temp.eq('late payer holds none', (select offer_id from private.billing where user_id = u6), null::text);
  perform pg_temp.eq('late payer renews at list', public.billing_amount_due(u6), 99);
  perform pg_temp.eq('cap held', (select count(*)::int from private.offer_members where offer_id = 't_one'), 1);
  perform pg_temp.eq('next quote list', (public.billing_upgrade_quote(pg_temp.uid(9007), 'home', 0, 'monthly')->>'nextCharge')::int, 99);
end $$;
update private.offers set joins_until = date '2000-01-01' where id = 't_one';

-- Three months, then list price, with one email 30 days before.
insert into private.offers (id, home_monthly, home_yearly, family_monthly, family_yearly, extra_monthly, extra_yearly, opens_on, months)
values ('t_dec', 49, 490, 89, 890, 29, 290, '2026-11-20', 3);
do $$
declare u uuid := pg_temp.uid(9008); paid int := 0; d date;
begin
  perform pg_temp.eq('special start R49', pg_temp.start(u, 'home', 'monthly'), 49);
  perform pg_temp.eq('until 3 months', (select offer_until from private.billing where user_id = u), date '2027-03-01');
  perform pg_temp.eq('Jan R49', public.billing_amount_due(u), 49);
  perform private.offer_end_mail('2026-12-31');
  perform pg_temp.eq('no mail yet', (select count(*)::int from public.email_queue where user_id = u and kind = 'bill_offer_ends'), 0);
  -- 1 Jan renewal (R49), then 1 Feb (R49), then 1 Mar is the first at list
  foreach d in array array[date '2027-01-01', date '2027-02-01'] loop
    perform set_config('t.today', d::text, true);
    perform public.billing_run(d);
    perform public.billing_charge_paid(c.reference, null, true)
       from private.billing_charges c where c.user_id = u and c.kind = 'renewal' and c.status = 'pending';
  end loop;
  perform pg_temp.eq('Mar at list', public.billing_amount_due(u), 99);
  perform pg_temp.eq('charged R49 twice', (select count(*)::int from private.billing_charges where user_id = u and kind = 'renewal' and amount = 49), 2);
  perform private.offer_end_mail('2027-01-29');
  perform private.offer_end_mail('2027-02-10');
  perform pg_temp.eq('one notice mail', (select count(*)::int from public.email_queue where user_id = u and kind = 'bill_offer_ends'), 1);
  perform pg_temp.eq('notice says R99', (select (data->>'amount')::int from public.email_queue where user_id = u and kind = 'bill_offer_ends'), 99);
  perform pg_temp.eq('notice was R49', (select (data->>'was')::int from public.email_queue where user_id = u and kind = 'bill_offer_ends'), 49);
end $$;

-- Comped never joins; the website sees the open offer.
select set_config('t.today', '2026-12-01', true) \g /dev/null
do $$
declare u uuid := pg_temp.uid(9009);
begin
  insert into private.billing (user_id, plan, comped) values (u, 'family', true);
  perform pg_temp.eq('comped quoted none', private.billing_offer_open(u, '2026-12-01'), null::text);
  perform pg_temp.eq('website home', (public.api_offer()->'prices'->'monthly'->>'home')::int, 49);
  perform pg_temp.eq('website list', (public.api_offer()->'listPrices'->'monthly'->>'home')::int, 99);
  perform pg_temp.eq('website offer id', public.api_offer()->'offer'->>'id', 't_dec');
end $$;

-- Screens: a Free account sees the offer, a paid one sees what it holds.
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.uid(9010), 'role', 'authenticated')::text, true);
  perform pg_temp.eq('free sees offer', (public.api_billing_status()->'prices'->'monthly'->>'home')::int, 49);
  perform pg_temp.eq('free sees list', (public.api_billing_status()->'listPrices'->'monthly'->>'home')::int, 99);
  perform pg_temp.eq('free quote list', (public.api_billing_quote('home', 'monthly')->>'listCharge')::int, 99);
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.uid(9003), 'role', 'authenticated')::text, true);
  perform pg_temp.eq('list payer sees list', (public.api_billing_status()->'prices'->'monthly'->>'home')::int, 99);
  perform pg_temp.eq('list payer no offer', public.api_billing_status()->'offer', 'null'::jsonb);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Emails quote the price this user pays (SOLAR-443): an offer left is not quoted again.
do $$
declare u uuid := pg_temp.uid(9011);
begin
  perform pg_temp.eq('new account email R49', (public.email_prices(pg_temp.uid(9012))->'prices'->'monthly'->>'home')::int, 49);
  perform pg_temp.eq('holder email R49', (public.email_prices(pg_temp.uid(9008))->'prices'->'monthly'->>'family')::int, 89);
  perform pg_temp.eq('leaver start R49', pg_temp.start(u, 'home', 'monthly'), 49);
  perform public.billing_book_change(u, 'free', null, null);
  perform set_config('t.today', '2027-01-01', true);
  perform public.billing_run('2027-01-01');
  perform pg_temp.eq('leaver on Free', (select plan from private.billing where user_id = u), 'free');
  perform pg_temp.eq('website still R49', (public.api_offer()->'prices'->'monthly'->>'home')::int, 49);
  perform pg_temp.eq('leaver email home R99', (public.email_prices(u)->'prices'->'monthly'->>'home')::int, 99);
  perform pg_temp.eq('leaver email family R199', (public.email_prices(u)->'prices'->'monthly'->>'family')::int, 199);
  perform pg_temp.eq('leaver email list', (public.email_prices(u)->'listPrices'->'monthly'->>'home')::int, 99);
  perform pg_temp.eq('leaver pays what email says', pg_temp.start(u, 'home', 'monthly'), 99);
end $$;

\set QUIET off
do $$ begin
  if exists (select 1 from pg_temp.fails) then
    raise exception E'offer tests failed:\n%', (select string_agg(what, E'\n' order by n) from pg_temp.fails);
  end if;
end $$;
select 'PASS' as offer_tests;
rollback;
