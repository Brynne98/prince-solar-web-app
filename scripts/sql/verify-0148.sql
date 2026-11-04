-- verify-0148: billing notices in the Notifications list (SOLAR-212). Each notice shows
-- while its state lasts and goes when it ends. Local stack only; one transaction, rolled back.
-- psql "$LOCAL_DB_URL" -X -q -f scripts/sql/verify-0148.sql   (exit code decides)
\set ON_ERROR_STOP 1
begin;

create function pg_temp.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', what; end if;
  raise notice 'ok: %', what;
end $$;
create function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
-- the pinned kinds the signed-in user sees, through the app's own call
create function pg_temp.kinds() returns text language sql as $$
  select coalesce(string_agg(x->>'kind', ',' order by o), '')
    from jsonb_array_elements(public.api_notifications()->'pinned') with ordinality as t(x, o) $$;
create function pg_temp.pin(k text) returns jsonb language sql as $$
  select x from jsonb_array_elements(public.api_notifications()->'pinned') x where x->>'kind' = k $$;

insert into auth.users (id, email, email_confirmed_at, aud, role)
values ('00000000-0000-0000-0000-00000000c001', 'n1@example.test', now(), 'authenticated', 'authenticated');
insert into public.plant_users (plant_id, user_id, plant_name, linked_at)
values (990201, '00000000-0000-0000-0000-00000000c001', 'Kloof St', '2026-01-01'),
       (990202, '00000000-0000-0000-0000-00000000c001', 'Farm', '2026-01-02');
select pg_temp.as_user('00000000-0000-0000-0000-00000000c001');
create temp table t as select private.billing_today() as d;

-- No billing row, no free week: nothing pinned.
select pg_temp.ok(pg_temp.kinds() = '', 'nothing pinned for an account with no billing or free week');

-- Home monthly, paid up, billing date in 20 days.
insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
select '00000000-0000-0000-0000-00000000c001', 'home', 'monthly', 1, d + 20 from t;
select pg_temp.ok(pg_temp.kinds() = '', 'nothing pinned while a monthly plan is paid and nothing is booked');

-- Payment failed.
update private.billing set state = 'past_due', past_due_since = (select d from t) where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'bill_failed', 'payment failed shows');
select pg_temp.ok((pg_temp.pin('bill_failed')->>'freeOn')::date >= (select d + 8 from t), 'payment failed: Free on day 8 at the earliest');
select pg_temp.ok((pg_temp.pin('bill_failed')->>'amount')::numeric > 0, 'payment failed: the amount due');
update private.billing set state = 'active', past_due_since = null where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = '', 'payment failed goes once paid');

-- A cancel booked, with Farm deleted on the date.
update private.billing set next_plan = 'free', plants_to_remove = '{990202}', remove_on = (select d + 20 from t)
 where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'bill_change', 'a booked cancel shows, deletion not yet within 3 days');
select pg_temp.ok(pg_temp.pin('bill_change')->>'nextPlan' = 'free' and pg_temp.pin('bill_change')->>'plan' = 'home', 'booked change: what undoes it');
-- 3 days before the deletion
update private.billing set remove_on = (select d + 3 from t), next_billing_date = (select d + 3 from t)
 where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'bill_removal_soon,bill_change', 'plants deleted soon shows 3 days before, first');
select pg_temp.ok(pg_temp.pin('bill_removal_soon')->'plants' = '["Farm"]', 'deleted soon: the plant names');
select pg_temp.ok((pg_temp.pin('bill_removal_soon')->>'room')::int = 1, 'deleted soon: a booked cancel leaves room for 1 plant');
update private.billing set remove_on = (select d + 4 from t) where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'bill_change', 'deleted soon not shown 4 days before');
-- undone
update private.billing set next_plan = null, plants_to_remove = '{}', remove_on = null where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = '', 'booked change goes once undone');

-- Switch to yearly booked, and fewer extra plants booked: both are booked changes.
update private.billing set next_period = 'yearly' where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'bill_change', 'a booked switch shows');
update private.billing set prepaid_on = (select d from t) where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = '', 'a paid switch to yearly has nothing to undo');
update private.billing set next_period = null, prepaid_on = null, plan = 'family', extra_plants = 1, next_extra_plants = 0
 where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'bill_change', 'fewer extra plants booked shows');
update private.billing set next_extra_plants = null where user_id = '00000000-0000-0000-0000-00000000c001';

-- Yearly renewal, 60 days before and not 61.
update private.billing set period = 'yearly', next_billing_date = (select d + 61 from t) where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = '', 'renewal not shown 61 days before');
update private.billing set next_billing_date = (select d + 60 from t) where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'bill_renewal_notice', 'renewal shows 60 days before');
select pg_temp.ok((pg_temp.pin('bill_renewal_notice')->>'amount')::numeric > 0, 'renewal: the amount');
update private.billing set next_plan = 'free' where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'bill_change', 'renewal gives way to a booked cancel');
update private.billing set next_plan = null where user_id = '00000000-0000-0000-0000-00000000c001';

-- Moved to Free, Farm stopped and deleted in 30 days.
update public.plant_users set paused = true where plant_id = 990202 and user_id = '00000000-0000-0000-0000-00000000c001';
update private.billing set plan = 'free', period = null, billing_day = null, next_billing_date = null, extra_plants = 0,
       plants_to_remove = '{990202}', remove_on = (select d + 30 from t)
 where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = '', 'on Free after a cancel that ended (no bill_free email): nothing');
insert into public.email_queue (user_id, kind, key, data, priority)
values ('00000000-0000-0000-0000-00000000c001', 'bill_free', 'bill_free:t', '{}', 1);
select pg_temp.ok(pg_temp.kinds() = 'bill_free', 'moved to Free shows');
select pg_temp.ok(pg_temp.pin('bill_free')->'kept' = '["Kloof St"]' and pg_temp.pin('bill_free')->'stopped' = '["Farm"]', 'moved to Free: kept and stopped plants');
update private.billing set remove_on = (select d + 2 from t) where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'bill_removal_soon,bill_free', 'on Free, deleted soon shows too');
-- a plant booked for deletion that is no longer linked: an empty list, not null
delete from public.plant_users where plant_id = 990202 and user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.pin('bill_removal_soon')->'plants' = '[]', 'deleted soon: unlinked plants give an empty list');
update private.billing set plants_to_remove = '{}', remove_on = null where user_id = '00000000-0000-0000-0000-00000000c001';
update public.email_queue set created_at = now() - interval '31 days' where kind = 'bill_free' and user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = '', 'moved to Free goes 30 days after its email');

-- The free week, for an account that never paid.
update private.billing set keep_until = null where user_id = '00000000-0000-0000-0000-00000000c001';
insert into private.free_week_logins (sunsynk_username, user_id, started_at)
values ('n1', '00000000-0000-0000-0000-00000000c001', now() - interval '4 days 23 hours');
select pg_temp.ok(pg_temp.kinds() = '', 'free week: nothing before day 5');
update private.free_week_logins set started_at = now() - interval '5 days 1 hour' where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'free_week_soon', 'free week ends soon shows from day 5');
select pg_temp.ok(pg_temp.pin('free_week_soon')->>'plant' = 'Kloof St' and (pg_temp.pin('free_week_soon')->>'perMonth')::int > 0, 'ends soon: plant and price');
update private.free_week_logins set started_at = now() - interval '7 days 1 hour' where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = 'free_week_ended', 'free week ended shows from day 7');
update private.free_week_logins set started_at = now() - interval '14 days 1 hour' where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = '', 'free week ended goes after 7 days');
update private.free_week_logins set started_at = now() - interval '7 days 1 hour' where user_id = '00000000-0000-0000-0000-00000000c001';
update private.billing set plan = 'home', period = 'monthly', billing_day = 1, next_billing_date = (select d + 30 from t)
 where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = '', 'free week ended goes once paid');

-- Comped: never anything.
update private.billing set plan = 'family', period = null, billing_day = null, next_billing_date = null, comped = true
 where user_id = '00000000-0000-0000-0000-00000000c001';
select pg_temp.ok(pg_temp.kinds() = '', 'comped: nothing pinned');

-- Another user sees none of it.
select pg_temp.as_user('00000000-0000-0000-0000-00000000c002');
select pg_temp.ok(pg_temp.kinds() = '', 'another user sees nothing');

rollback;
