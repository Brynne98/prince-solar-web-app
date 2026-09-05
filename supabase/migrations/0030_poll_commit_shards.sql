-- ============================================================================
-- 0030 — one-transaction poll commit, sharded poll fan-out.
--
-- Two scaling problems in the minute logger, both in `poll`:
--
--   1. Each account's minute was written in eight round trips (agg prev-row select,
--      gap_record, agg upsert, readings upsert, strings upsert, meta_upsert,
--      inverters_seed, account_access_set). Slow, and a failure part-way left a
--      half-written minute: readings without strings, or strings without the agg row.
--
--      poll_commit() takes the whole minute for one account as jsonb and writes it
--      in one transaction. Everything lands or nothing does.
--
--   2. pg_cron fired ONE poll invocation per minute that looped over every account
--      serially inside a 50 s budget — a hard ceiling somewhere around 15 accounts.
--
--      The cron job now fans out: poll_shards() decides how many invocations this
--      minute needs (about POLL_PER_SHARD accounts each) and the job POSTs one request
--      per shard carrying {shard, shards, delay_ms}. `poll` keeps only the accounts
--      whose id hashes into its shard, so each account is handled by exactly one
--      invocation per minute (no two isolates refreshing the same token at once), and
--      invocations run in parallel on the edge runtime.
--
--      delay_ms staggers shards across the minute so the whole fleet does not hit
--      SunSynk at second zero. Three buckets, 0/10/20 s; the pg_net timeout is
--      raised to 55 s to leave the same working budget after the longest delay.
--
-- With one account today this schedules exactly one request per minute with
-- delay 0 — the same behaviour as before.
--
-- Local stack: the cron section is a no-op where pg_cron/pg_net are not enabled,
-- same as 0009. poll_commit and poll_shards are created everywhere.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. poll_commit — the whole minute for one account, atomically.
--
-- p_readings / p_strings: arrays of row objects whose keys are column names
--   (the same shape `poll` used to upsert through PostgREST). Populated with
--   jsonb_populate_recordset so a column added to the table later needs no change
--   here. Rows without plant_id are dropped: nothing could ever read them.
-- p_agg: one {plant_id, pv_w, load_w, batt_w, grid_w, soc} per plant, computed by
--   the function so the SOC-over-valid-readings rule stays in one place.
-- p_meta / p_inverters: as for meta_upsert / inverters_seed.
-- p_access / p_expires: the account's current access token, recorded together
--   with last_ok_at (was account_access_set).
--
-- Semantics preserved from the old write path:
--   readings, strings  last write wins   (was upsert; here delete+insert so no
--                                          column list has to be maintained)
--   agg_minute         first write wins  (INSERT OR IGNORE — recovered rows are
--                                          never overwritten by a late poller)
--   gap                recorded when this minute lands > 90 s after the plant's
--                      previous agg row, so `recover` can backfill the window.
-- ---------------------------------------------------------------------------
create or replace function public.poll_commit(
  p_account   uuid,
  p_ts        bigint,
  p_readings  jsonb,
  p_strings   jsonb,
  p_agg       jsonb,
  p_meta      jsonb,
  p_inverters jsonb,
  p_access    text,
  p_expires   bigint
)
returns jsonb
language plpgsql
security definer
set search_path = pg_temp
as $$
declare
  n_readings int := 0;
  n_strings  int := 0;
  gaps       bigint[] := '{}';
  plants     bigint[] := '{}';
  a          record;
  prev_ts    bigint;
begin
  -- Staging tables are temp + on commit drop, but a caller that commits several
  -- minutes in one transaction (tests, a future batch path) would otherwise find
  -- them still there; drop first so the function is safe to call repeatedly.
  if to_regclass('pg_temp._rd') is not null then drop table _rd; end if;
  if to_regclass('pg_temp._st') is not null then drop table _st; end if;

  -- readings: last write wins
  create temp table _rd on commit drop as
    select * from jsonb_populate_recordset(null::public.readings, coalesce(p_readings, '[]'::jsonb))
     where plant_id is not null;
  delete from public.readings r using _rd where r.ts = _rd.ts and r.sn = _rd.sn;
  insert into public.readings select * from _rd;
  get diagnostics n_readings = row_count;

  -- strings: last write wins
  create temp table _st on commit drop as
    select * from jsonb_populate_recordset(null::public.strings, coalesce(p_strings, '[]'::jsonb))
     where plant_id is not null;
  delete from public.strings s using _st where s.ts = _st.ts and s.sn = _st.sn and s.no = _st.no;
  insert into public.strings select * from _st;
  get diagnostics n_strings = row_count;

  -- one aggregate row per plant, first write wins; gap detection against the
  -- plant's previous row (same 90 s rule as the old poller and db.js recordPoll)
  for a in
    select (r->>'plant_id')::bigint as plant_id,
           nullif(r->>'pv_w',   '')::int as pv_w,
           nullif(r->>'load_w', '')::int as load_w,
           nullif(r->>'batt_w', '')::int as batt_w,
           nullif(r->>'grid_w', '')::int as grid_w,
           nullif(r->>'soc',    '')::int as soc
      from jsonb_array_elements(coalesce(p_agg, '[]'::jsonb)) r
     where r->>'plant_id' is not null
  loop
    plants := plants || a.plant_id;

    select max(ts) into prev_ts from public.agg_minute where plant_id = a.plant_id;
    if prev_ts is not null and p_ts - prev_ts > 90 then
      insert into private.gaps (plant_id, from_ts, to_ts) values (a.plant_id, prev_ts, p_ts)
      on conflict (plant_id, from_ts) do nothing;
      gaps := gaps || a.plant_id;
    end if;

    insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
    values (a.plant_id, p_ts, a.pv_w, a.load_w, a.batt_w, a.grid_w, a.soc, 'poller')
    on conflict (plant_id, ts) do nothing;
  end loop;

  -- inverter identity + mirror + the account's token, as before
  perform public.meta_upsert(coalesce(p_meta, '[]'::jsonb));
  perform public.inverters_seed(coalesce(p_inverters, '[]'::jsonb));
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires,
         last_ok_at = now(), last_error = null
   where id = p_account;

  return jsonb_build_object(
    'readings', n_readings,
    'strings',  n_strings,
    'plants',   to_jsonb(plants),
    'gaps',     to_jsonb(gaps));
end;
$$;

revoke all on function public.poll_commit(uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb, text, bigint)
  from public, anon, authenticated;
grant execute on function public.poll_commit(uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb, text, bigint)
  to service_role;

comment on function public.poll_commit is
  'One account''s minute (readings, strings, agg rows, meta, inverters, token) in a single transaction. service_role only.';

-- ---------------------------------------------------------------------------
-- 2. poll_shards — how many poll invocations this minute needs.
--
-- Lives in `private` so PostgREST never exposes it; the cron job runs as postgres
-- and can call it. Always returns at least one row so a deployment with no active
-- accounts still gets its bootstrap tick.
--
-- delay_ms spreads shards over the minute in 10 s buckets: shard 0 at :00, 1 at
-- :10, 2 at :20, 3 at :00 again, ... The bucket count is capped at 3 so the
-- longest wait leaves >= 35 s of the pg_net timeout for the actual work.
-- ---------------------------------------------------------------------------
create or replace function private.poll_shards(p_per_shard int default 10)
returns table (shard int, shards int, delay_ms int)
language sql
stable
set search_path = pg_temp
as $$
  with n as (
    select greatest(1, ceil(count(*)::numeric / greatest(p_per_shard, 1)))::int as shards
      from private.sunsynk_accounts
     where status = 'active'
  )
  select s.i, n.shards, (s.i % 3) * 10000
    from n, generate_series(0, n.shards - 1) as s(i)
$$;

-- ---------------------------------------------------------------------------
-- 3. Reschedule sunsynk-poll as the fan-out. Same guard and same Vault-held
-- service_role_key as 0009; production-only by construction.
-- ---------------------------------------------------------------------------
do $$
declare
  fn_url text := 'https://pmakzojwhouamawgszrc.functions.supabase.co/poll';
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - skipping poll reschedule (expected on the local stack)';
    return;
  end if;

  if exists (select 1 from cron.job where jobname = 'sunsynk-poll') then
    perform cron.unschedule('sunsynk-poll');
  end if;

  perform cron.schedule('sunsynk-poll', '* * * * *', format($job$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        'Content-Type', 'application/json'),
      body := jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms),
      timeout_milliseconds := 55000)
    from private.poll_shards() s;
  $job$, fn_url));

  raise notice 'rescheduled sunsynk-poll as a sharded fan-out';
exception when others then
  raise notice 'poll reschedule skipped: %', sqlerrm;
end $$;
