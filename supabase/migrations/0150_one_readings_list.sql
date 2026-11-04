-- ============================================================================
-- 0150 — one list of a plant's readings (SOLAR-255).
--
-- Stop (plant_wipe_readings, 0125) and remove (purge_plant, 0073) each kept their
-- own copy of the readings tables. private.plant_readings_delete is now that list;
-- both call it. A new readings table goes there once.
--   - Stop keeps settings, logins, inverters and alerts, as in 0125.
--   - Remove also deletes the alert state (0124 on), which purge_plant missed:
--     a removed plant left rows in plant_, inverter_ and string_alert_state.
-- free_trim_done (0111) now goes on remove too.
-- grid_cuts, named in the ticket, is grid_off since 0069; both lists had it.
-- ============================================================================

-- Every reading a plant has, with a count per table. The caller holds the plant's lock.
create or replace function private.plant_readings_delete(p_plant bigint)
returns jsonb
language plpgsql
set search_path = public, private, pg_temp
as $$
declare
  out jsonb := '{}'::jsonb;
  n bigint;
begin
  delete from public.readings            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings', n);
  delete from public.strings             where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings', n);
  delete from public.readings_5m         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings_5m', n);
  delete from public.strings_5m          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings_5m', n);
  delete from public.agg_minute          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_minute', n);
  delete from public.agg_5m              where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_5m', n);
  delete from public.plant_energy        where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_energy', n);
  delete from public.inverter_history    where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history', n);
  delete from public.inverter_history_5m where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history_5m', n);
  delete from public.grid_off            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('grid_off', n);
  delete from private.gaps               where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('gaps', n);
  delete from private.grid_off_progress  where plant_id = p_plant;
  delete from private.free_trim_done     where plant_id = p_plant;
  return out;
end $$;
revoke all on function private.plant_readings_delete(bigint) from public, anon, authenticated;

-- 0125's body; the deletes are now plant_readings_delete. gaps is counted now.
create or replace function private.plant_wipe_readings(p_plant bigint)
returns bigint
language plpgsql
set search_path = public, private, pg_temp
as $$
declare total bigint;
begin
  perform pg_advisory_xact_lock(p_plant);
  -- Started again while it waited: keep everything.
  if exists (select 1 from public.plant_users where plant_id = p_plant and not paused) then
    delete from private.plant_wipe where plant_id = p_plant;
    return 0;
  end if;
  select coalesce(sum(v::bigint), 0) into total from jsonb_each_text(private.plant_readings_delete(p_plant)) as t(k, v);
  update public.plant_config
     set backfill_next = null, backfill_until = null, backfill_tries = 0, temp_next = null
   where plant_id = p_plant;
  delete from private.plant_wipe where plant_id = p_plant;
  return total;
end $$;
revoke all on function private.plant_wipe_readings(bigint) from public, anon, authenticated;

-- 0073's body; the readings are now plant_readings_delete. Adds the alert state,
-- and a stop's wipe still queued.
create or replace function private.purge_plant(p_plant bigint, p_wait boolean default true)
returns jsonb
language plpgsql
set search_path = public, private, pg_temp
as $$
declare
  out jsonb;
  n bigint;
begin
  if p_wait then
    perform pg_advisory_xact_lock(p_plant);
  elsif not pg_try_advisory_xact_lock(p_plant) then
    return null;
  end if;
  if not exists (select 1 from private.plant_purge where plant_id = p_plant) then
    return null;
  end if;
  if exists (select 1 from public.plant_users where plant_id = p_plant) then
    delete from private.plant_purge where plant_id = p_plant;
    return jsonb_build_object('skipped', 'linked again');
  end if;

  out := private.plant_readings_delete(p_plant);
  delete from public.plant_config          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from public.config_changes        where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('config_changes', n);
  delete from private.meta                 where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  delete from private.plant_alert_state    where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_alert_state', n);
  delete from private.inverter_alert_state where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_alert_state', n);
  delete from private.string_alert_state   where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('string_alert_state', n);
  delete from private.plant_wipe           where plant_id = p_plant;
  delete from private.plant_purge          where plant_id = p_plant;
  return out;
end $$;
