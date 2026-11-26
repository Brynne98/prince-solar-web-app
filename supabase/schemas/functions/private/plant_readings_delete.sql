CREATE OR REPLACE FUNCTION private.plant_readings_delete(p_plant bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  out jsonb := '{}'::jsonb;
  n bigint;
  t0 timestamptz := clock_timestamp();                                    -- 0270
  t1 timestamptz;                                                         -- 0270
  t2 timestamptz;                                                         -- 0270
begin
  begin                                                                   -- 0270
  -- waits for a running rollup slice (SOLAR-651), so the slice cannot write back what this deletes
  perform pg_advisory_xact_lock_shared(8, 651);
  t1 := clock_timestamp();                                                -- 0270
  delete from public.readings            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings', n);
  delete from public.strings             where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings', n);
  t2 := clock_timestamp();                                                -- 0270
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
  exception when query_canceled then                                     -- 0270
    -- the timeout rolls back the log row below; the split goes to the server log instead
    raise log 'plant_readings_delete canceled: plant % wait % ms, raw % ms, rest % ms', p_plant,
      round(extract(epoch from coalesce(t1, clock_timestamp()) - t0) * 1000),
      round(extract(epoch from coalesce(t2, clock_timestamp()) - coalesce(t1, clock_timestamp())) * 1000),
      round(extract(epoch from clock_timestamp() - coalesce(t2, clock_timestamp())) * 1000);
    raise;
  end;
  insert into private.history_delete_log                                 -- 0270
    (plant_id, caller, timeout, wait_ms, raw_ms, rest_ms, counts)
  values (p_plant,
    coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role', session_user::text),
    current_setting('statement_timeout', true),
    round(extract(epoch from t1 - t0) * 1000),
    round(extract(epoch from t2 - t1) * 1000),
    round(extract(epoch from clock_timestamp() - t2) * 1000),
    out);
  return out;
end $function$;
