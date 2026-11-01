-- Go-live clean-up (SOLAR-267, SOLAR-270): removes the Paystack test-mode tester's
-- billing rows, charges and billing emails, and every fake SunSynk login (name@mock) with
-- its fake plants (ids 900000000 to 900999999, the mock's range; their readings are wiped
-- by the purge job).
-- The tester's real plants and readings stay, and with no billing row the account reads
-- as Free. Run once, before the live key is set:
--   supabase db query --linked -f scripts/sql/go-live-tester-cleanup.sql
-- One statement, so all or nothing. Prints how many rows went; accounts 0 means the
-- email matched no one and no billing was removed.
with t as (select id from auth.users where email = 'brynneprince98+test@gmail.com'),
c as (delete from private.billing_charges where user_id in (select id from t) returning 1),
b as (delete from private.billing where user_id in (select id from t) returning 1),
-- billing emails only (bill_paid, bill_failed, bill_refund, ...); welcome, reports and alerts stay
e as (delete from public.email_queue where user_id in (select id from t) and kind like 'bill\_%' returning 1),
m as (delete from private.sunsynk_accounts where sunsynk_username like '%@mock' returning refresh_secret_id),
v as (delete from vault.secrets where id in (select refresh_secret_id from m) returning 1),
p as (delete from public.plant_users where plant_id between 900000000 and 900999999 returning plant_id),
w as (select private.plants_tombstone(array_agg(distinct plant_id)) from p)
select (select count(*) from t) as accounts, (select count(*) from c) as charges,
       (select count(*) from b) as billing, (select count(*) from e) as emails,
       (select count(*) from m) as fake_logins, (select count(distinct plant_id) from p) as fake_plants
  from w;  -- from w: runs the purge queueing
