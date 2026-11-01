-- Go-live clean-up (SOLAR-267): removes the Paystack test-mode tester's billing rows,
-- charges and billing emails. Nothing else: the tester's plants and readings stay, and
-- with no billing row the account reads as Free. Run once, before the live key is set:
--   supabase db query --linked -f scripts/sql/go-live-tester-cleanup.sql
-- One statement, so all or nothing. Prints how many rows went; accounts 0 means the
-- email matched no one and nothing was removed.
with t as (select id from auth.users where email = 'brynneprince98+test@gmail.com'),
c as (delete from private.billing_charges where user_id in (select id from t) returning 1),
b as (delete from private.billing where user_id in (select id from t) returning 1),
-- billing emails only (bill_paid, bill_failed, bill_refund, ...); welcome, reports and alerts stay
e as (delete from public.email_queue where user_id in (select id from t) and kind like 'bill\_%' returning 1)
select (select count(*) from t) as accounts, (select count(*) from c) as charges,
       (select count(*) from b) as billing, (select count(*) from e) as emails;
