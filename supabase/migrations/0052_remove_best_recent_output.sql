-- ============================================================================
-- 0052 — remove the dotted "best recent output" line (0051) for now. The chart no
-- longer asks for it; the smooth best-day curve that replaces it is planned in
-- BEST_DAY_CURVE.md. Ship after the frontend: an older page swallows the failed call.
-- Nothing else in the database calls this function (checked 14 Sep 2026).
-- ============================================================================

drop function if exists public.api_trends_potential(date, bigint);
