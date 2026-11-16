-- ============================================================================
-- 0219 — a payment that was refunded and never applied is not a plan (SOLAR-572).
--
-- Before: private.had_plan (0207) counted every charge with status 'paid'. A first
-- payment that was taken, not applied and marked for refund ('refund: ...',
-- billing_charge_paid) counted too. That account lost the launch price and, with no
-- plant yet, its free week.
--
-- Now: a charge marked for refund does not count. Every reader of had_plan follows:
-- api_me's wall, no_week, week_start, free_week_mail, unpaid_delete, billing_offer_open.
-- ============================================================================

create or replace function private.had_plan(p_user uuid)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select exists (select 1 from private.billing_charges c
                  where c.user_id = p_user and c.status = 'paid' and coalesce(c.error, '') not like 'refund%')
$$;
revoke all on function private.had_plan(uuid) from public, anon, authenticated;
