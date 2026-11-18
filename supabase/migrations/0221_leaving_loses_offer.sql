-- ============================================================================
-- 0221 — leaving a plan loses its offer (SOLAR-581, decided by Brynne 2026-11-18).
--
-- Before (0212): an account that joined an offer got it again after its plan
-- ended (a cancel or a failed card), while the offer was open. The emails said
-- the launch price was "yours while you stay", which said the opposite.
--
-- Now: an offer is for an account that never paid. A plan that ends, for any
-- reason, loses its offer; coming back pays the list price. A paid plan keeps
-- its offer through billing_offer (unchanged), and a cancel undone before its
-- date never left the plan, so it keeps it too.
--
-- billing_offer_open is only asked for accounts with no plan (billing_offer_now,
-- billing_upgrade_quote from Free, free_week_mail, api_offer), so dropping the
-- member clause is the whole change. Its place in max_payers stays counted.
-- ============================================================================

create or replace function private.billing_offer_open(p_user uuid, p_day date)
returns text language sql stable set search_path = public, private, pg_temp as $$
  select o.id from private.offers o
   where o.opens_on <= p_day and (o.joins_until is null or p_day <= o.joins_until)
     and not coalesce((select b.comped from private.billing b where b.user_id = p_user), false)
     and not private.had_plan(p_user)
     and (o.max_payers is null or (select count(*) from private.offer_members m where m.offer_id = o.id) < o.max_payers)
   order by o.opens_on desc, o.created_at desc
   limit 1
$$;
