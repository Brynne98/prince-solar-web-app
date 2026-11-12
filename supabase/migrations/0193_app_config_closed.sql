-- ============================================================================
-- 0193 — Signed-in users cannot read app_config (SOLAR-532, security review 6).
--
-- app_config_read let every signed-in user read the whole table over REST. It
-- holds LAT, LON and CALIBRATION_PLANT: one home's location and plant id from
-- the single-user days, plus the server's job cursors and error gates.
--
-- The browser never reads the table. Its one path in is api_overview, which is
-- security definer: plant_cfg, cfg and calibration_plant run inside it as the
-- owner, so they need no right for the caller. The server functions use the
-- service key. So the policy, the table right and the three helpers' execute
-- right all go; a user calling cfg('LAT') over REST is refused too.
--
-- The rows stay: plant_cfg still falls back to them and calibration_plant
-- still reads CALIBRATION_PLANT.
-- ============================================================================

drop policy if exists app_config_read on public.app_config;
revoke all on public.app_config from public, anon, authenticated;

revoke all on function public.cfg(text) from public, anon, authenticated;
revoke all on function public.calibration_plant() from public, anon, authenticated;
revoke all on function public.plant_cfg(bigint) from public, anon, authenticated;
