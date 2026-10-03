-- ============================================================================
-- 0066 — api_balance runs as its owner, like api_overview. (SOLAR-35)
--
-- After 0064 api_balance still hit the 8 s statement timeout on most calls. It
-- was the one hot api_* function left security invoker, so every readings scan
-- carried the RLS qual plant_id IN (SELECT my_plant_ids()) and could not prune
-- partitions or stop early on the (plant_id, ts) index: it read every
-- household's rows, then filtered. api_overview has the same lookups as definer
-- and averages 42 ms.
--
-- Measured 2026-10-03 on production, as Brynne's account, inside a rolled-back
-- ALTER: 0.9 s cold, then 40 ms (invoker: 8-9 s cold, 0.8-1.4 s warm).
--
-- Access is unchanged: my_plant(p_plant) still raises unless auth.uid() is
-- linked to the plant, and EXECUTE stays with authenticated and service_role
-- only (no anon, no PUBLIC). search_path is already pinned.
-- ============================================================================

alter function public.api_balance(bigint) security definer;
