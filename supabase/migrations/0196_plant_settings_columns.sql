-- ============================================================================
-- 0196 — An owner updates only the settings columns of plant_config
--        (SOLAR-536, second security review N1).
--
-- authenticated held UPDATE on the whole table. The row rule plant_config_write
-- checks only that the plant is theirs, so an owner could also set the server's
-- own fields: backfill_next / backfill_until / backfill_tries (the history
-- fetch), temp_next / temp_tries, has_grid, features_source, batt_sign_source,
-- updated_by. Dates set far back made the server fetch months from SunSynk again.
--
-- What the browser sends (public/data.jsx savePlantConfig; callers: Plant
-- settings in tabs.jsx, First steps in app.jsx), and nothing else:
--   tariff_import, battery_reserve_pct, battery_reserve_confirmed,
--   battery_kwh, battery_groups, system_kwp, panel_groups
-- No api_* function writes this table as the caller: every function that does
-- runs with its owner's rights, and the server functions use service_role.
--
-- The BEFORE triggers still set updated_at and updated_by on a user's save
-- (plant_config_touch): a trigger's own assignments need no column right.
-- plant_config_batt_sign_guard and plant_config_features_guard mark a user's
-- change to batt_positive_means / has_battery / has_grid; no screen sends those
-- columns, so a user can no longer reach them. To give one back, grant its
-- column here; the guard then marks it as before.
--
-- Revoking the table right also clears every column right, so this runs twice
-- without error and ends in the same state.
-- ============================================================================

revoke update on public.plant_config from authenticated;
grant update (tariff_import, battery_reserve_pct, battery_reserve_confirmed,
              battery_kwh, battery_groups, system_kwp, panel_groups)
  on public.plant_config to authenticated;
