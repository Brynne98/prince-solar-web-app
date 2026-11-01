-- Go-live clean-up (SOLAR-267): removes the Paystack test-mode tester's billing rows,
-- charges and billing emails. Nothing else: the tester's plants and readings stay, and
-- with no billing row the account reads as Free. Run once, before the live key is set:
--   psql "$PROD_DB_URL" -v tester=<auth user id> -f scripts/sql/go-live-tester-cleanup.sql
-- One transaction: it prints the row counts and stops on any error.
\set ON_ERROR_STOP on
begin;
select count(*) as charges_removed from private.billing_charges where user_id = :'tester'::uuid;
delete from private.billing_charges where user_id = :'tester'::uuid;
delete from private.billing where user_id = :'tester'::uuid;
-- billing emails only (bill_paid, bill_failed, bill_refund, ...); welcome, reports and alerts stay
delete from public.email_queue where user_id = :'tester'::uuid and kind like 'bill\_%';
commit;
