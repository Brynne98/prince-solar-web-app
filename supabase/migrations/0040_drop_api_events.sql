-- ============================================================================
-- 0040 — drop the Events tab's reader.
--
-- api_events shipped in 0038 and was corrected in 0039. Looked at against real
-- history it did not earn its place: over 30 days it produced 135 rows, and 120
-- of them were a daily summary — first sun, peak solar, heaviest load, last sun,
-- every day forever. Fifteen were things that actually happened. A log that is
-- 89% filler trains you to scroll past it, which is worse than not having one.
--
-- What was worth keeping is the detection, not the tab, and none of it is lost
-- here: gaps and cloud-recovered minutes are still derivable from agg_minute
-- (`source`), and the SQL is in 0038/0039 in git if a narrower fault log is ever
-- wanted. Nothing else calls either function — the frontend route went with the
-- tab in this same commit.
-- ============================================================================
drop function if exists public.api_events(integer, bigint);
drop function if exists public.fmt_dur(bigint);
