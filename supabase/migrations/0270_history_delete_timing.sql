-- ============================================================================
-- 0270 — each history delete is timed; an alarm over 3 s (SOLAR-659, step 1).
--
-- Removing or switching plants (api_choose_plants, api_link_remove) deletes the plant's
-- history inside the app request (8 s statement_timeout), one billing.purge_now per plant,
-- all in one transaction. Since 0266 each delete first waits for a running rollup slice
-- (key 8, 651). Not hit yet; this step measures it so step 2 is chosen from numbers:
-- split the rollup slices by plant (the wait is long) or move the delete out of the
-- request (the delete is long).
--   1. private.history_delete_log: one row per private.plant_readings_delete call, with
--      the transaction id (one app request), the caller role, the timeout in force, ms
--      waiting for the key, ms on the raw tables (readings, strings), ms on the rest, and
--      the rows per table. Kept 90 days.
--   2. private.plant_readings_delete writes that row. Same deletes, same return value.
--   3. Cron history-delete-slow every 15 min: drops old rows, commits, then fails when in
--      the last 24 h one delete took over 3 s, or the deletes of one app request
--      (authenticated or service_role) added up to over 3 s. The cron failure check (0180)
--      alerts. Background deletes (billing.delete_due) count singly: a canary.
-- A delete stopped by the 8 s timeout rolls back its own row; it writes the same split to the
-- server log (LOG level), and the app reports the error to PostHog from both screens.
-- Body: plant_readings_delete 0266; only the lines marked 0270 change.
-- ============================================================================

-- ── 1. the log ──────────────────────────────────────────────────────────────
create table if not exists private.history_delete_log (
  at        timestamptz not null default now(),
  xid       xid8 not null default pg_current_xact_id(),
  plant_id  bigint not null,
  caller    text not null,
  timeout   text,
  wait_ms   integer not null,
  raw_ms    integer not null,
  rest_ms   integer not null,
  counts    jsonb not null
);
create index if not exists history_delete_log_at on private.history_delete_log (at);
alter table private.history_delete_log enable row level security;
revoke all on table private.history_delete_log from public, anon, authenticated;

-- ── 2. the delete, timed ────────────────────────────────────────────────────
create or replace function private.plant_readings_delete(p_plant bigint)
returns jsonb
language plpgsql
set search_path to 'public', 'private', 'pg_temp'
as $function$
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

-- ── 3. the alarm ────────────────────────────────────────────────────────────
create or replace procedure private.history_delete_check(p_slow_ms integer default 3000)
language plpgsql
as $$  -- no SET clause: a procedure with one cannot COMMIT
declare
  w record;
begin
  delete from private.history_delete_log where at < now() - interval '90 days';
  commit;  -- kept when the alarm below fails the run

  select * into w from (
    select plant_id::text as what, caller, wait_ms + raw_ms + rest_ms as ms, wait_ms, raw_ms, rest_ms
      from private.history_delete_log where at > now() - interval '24 hours'
    union all
    select count(*) || ' plants', min(caller), sum(wait_ms + raw_ms + rest_ms), sum(wait_ms), sum(raw_ms), sum(rest_ms)
      from private.history_delete_log where at > now() - interval '24 hours' and caller in ('authenticated', 'service_role')
     group by xid having count(*) > 1
  ) t where ms > p_slow_ms order by ms desc limit 1;
  if found then
    raise exception 'history delete over % ms in 24 h: % % % ms (wait %, raw %, rest %), see SOLAR-659',
      p_slow_ms, w.what, w.caller, w.ms, w.wait_ms, w.raw_ms, w.rest_ms;
  end if;
end $$;
revoke all on procedure private.history_delete_check(integer) from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'history-delete-slow') then
    perform cron.unschedule('history-delete-slow');
  end if;
  perform cron.schedule('history-delete-slow', '*/15 * * * *', 'call private.history_delete_check()');
end $$;
