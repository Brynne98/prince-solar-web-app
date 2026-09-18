-- ============================================================================
-- `grid_burst` comes out. It was built for one question and it answered it.
--
-- 0029 added the table and the burst block in `poll` on 5 Sep 2026 to find out
-- what this firmware reports while the grid is genuinely dead, because 0015's
-- voltage test and 0017's alert wording both rested on an assumption nobody had
-- observed. Brynne's decision the same day was that it is a diagnostic and comes
-- out once the answer is written down. It is written down: FEATURES.md, "Answered
-- — grid presence", 0055's header, and OUTAGE_2026-09-18.md.
--
-- WHAT IT CAUGHT, 18 Sep 2026, 16:09-17:20 SAST, ~10 s resolution throughout:
--
--   Dead grid   grid_volt_v 15.2 V decaying to 6.5 V on the master and a flat
--               5.0-5.5 V on the slave -- sensor float, never 0 V on this plant,
--               though plant 495944's three inverters did read exactly 0.0 V.
--               grid_freq_hz 0.00, grid_w 0, grid_relay_status '0'. Output pinned
--               to 230.0 V / 50.00 Hz: islanding.
--   Return      17:18:14, one sample: grid_volt_v 6.6 -> 241.0 V and grid_freq_hz
--               0.00 -> 49.86 TOGETHER, relay still '0', grid_w still 0.
--   Reconnect   92 s of that state, then 17:20:06 the relay closes: relay '1',
--               237.6 V / 49.83 Hz, 187 W importing, and output jumps from the
--               islanded 230.0 V / 50.00 Hz to 237.7 V / 49.90 Hz -- one bus again.
--
-- Three things only the sub-minute sampling could show, all of them now settled:
-- that a dead grid reads a few volts rather than zero; that frequency returns with
-- the mains and not with the relay, which kills the "frequency tracks the relay"
-- explanation 0029's own header offered; and that the reconnect delay is about
-- 90 s, which is comfortably inside the 2-minute `grid_back` debounce, so no
-- special handling of that window is needed.
--
-- WHAT STAYS. `burstTrigger` in `poll` is renamed `outageSignal` and kept: three
-- unrelated things depend on knowing a row looks like an outage -- `canCarry`
-- refuses to carry one forward, `wantEndpoints` forces the load and output reads,
-- and `fetchInverter` reads the far side of the relay early. Only the sampling
-- loop, its four constants, the `waitUntil` plumbing and this table go.
--
-- WHAT IS NOT FORECLOSED. The burst only ever armed on the minute AFTER a poll saw
-- the trigger, so it could never answer the 4 Sep question of an outage shorter
-- than the 60 s poll interval. Dropping it costs nothing there. If that question
-- matters later it wants continuous 10 s grid polling, not this table.
--
-- Cost while it lived: 12 rows a minute for the whole of any outage or deliberate
-- relay-open stretch, plus 10 API calls per inverter per triggered minute against
-- a rate limit whose real shape is still unclear.
-- ============================================================================

-- private.purge_plant: 0050's body with the grid_burst line removed. Nothing else
-- changes, and the `plant_row_guard` trigger on the table goes with the table.
create or replace function private.purge_plant(p_plant bigint, p_wait boolean default true)
returns jsonb
language plpgsql
set search_path = public, private, pg_temp
as $$
declare
  out jsonb := '{}'::jsonb;
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

  delete from public.readings         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings', n);
  delete from public.strings          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings', n);
  delete from public.agg_minute       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_minute', n);
  delete from public.plant_energy     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_energy', n);
  delete from public.inverter_history where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history', n);
  delete from public.plant_config     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from private.gaps            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('gaps', n);
  delete from private.meta            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  delete from private.plant_purge     where plant_id = p_plant;
  return out;
end $$;

drop table if exists public.grid_burst;
