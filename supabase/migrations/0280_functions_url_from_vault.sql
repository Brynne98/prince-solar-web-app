-- ============================================================================
-- SOLAR-679 F11 (absorbs SOLAR-670): no database names the production address.
--
-- private.call_fn, public.plant_bootstrap_kick and private.first_load_continue posted to a
-- hard-coded https://<production>.functions.supabase.co, so any database with pg_cron and
-- pg_net on (a rebuild, a local copy) called production's functions. They now read the
-- address from the Vault secret 'functions_url' (no trailing slash):
--   production: https://<ref>.functions.supabase.co        (set by the release workflow)
--   local:      http://supabase_kong_<project_id>:8000/functions/v1   (scripts/staging-local.sh)
-- With no secret, a call raises instead of guessing.
--
-- private.schedule_jobs() holds the cron schedule, as production ran it on 2026-11-26. It is
-- called here where pg_cron is on (production: the same 17 jobs, updated in place by name),
-- and by the local staging setup. A cron change edits it and calls it from a migration.
--
-- Release order: the 'functions_url' secret must exist before this lands. Where pg_cron is on,
-- the migration raises without it and rolls back. The release workflow sets it first.
-- ============================================================================

create or replace function private.functions_url()
 returns text
 language plpgsql
 stable security definer
 set search_path to 'pg_temp'
as $function$
declare u text;
begin
  select decrypted_secret into u from vault.decrypted_secrets where name = 'functions_url';
  if coalesce(u, '') = '' then
    raise exception 'Vault secret functions_url is not set: no functions to call' using errcode = '55000';
  end if;
  return rtrim(u, '/');
end $function$;
revoke all on function private.functions_url() from public, anon, authenticated;

CREATE OR REPLACE FUNCTION private.call_fn(p_path text, p_body jsonb DEFAULT '{}'::jsonb, p_timeout_ms integer DEFAULT 55000)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare rid bigint;
begin
  rid := net.http_post(
    url := private.functions_url() || '/' || p_path,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
      'Content-Type', 'application/json'),
    body := p_body,
    timeout_milliseconds := p_timeout_ms);
  insert into private.fn_calls (id, fn, shard, timeout_ms)
  values (rid, split_part(split_part(p_path, '?', 1), '/', 1), (p_body ->> 'shard')::int, p_timeout_ms)
  on conflict (id) do nothing;
  return rid;
end $function$;

CREATE OR REPLACE FUNCTION public.plant_bootstrap_kick(p_plant bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  fn_base text;
  fn text;
  auth jsonb;
  acc uuid;
  rid bigint;                                                             -- 0235
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net not enabled here - not kicking bootstrap for plant %', p_plant;
    return;
  end if;
  fn_base := private.functions_url();                                     -- 0280
  auth := jsonb_build_object(
    'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
    'Content-Type', 'application/json');
  foreach fn in array array['sync-plant-energy', 'recover'] loop
    rid := net.http_post(                                                 -- 0235: keep the id
      url := fn_base || '/' || fn || '?plant=' || p_plant,
      headers := auth,
      body := '{}'::jsonb,
      timeout_milliseconds := 150000);
    if fn = 'recover' then                                                -- 0235
      insert into private.recover_kicks (plant_id, request_id)
        select p_plant, rid where exists (select 1 from public.plant_config where plant_id = p_plant)
        on conflict (plant_id) do update set request_id = excluded.request_id, at = now();
    end if;
  end loop;
  select account_id into acc from public.plant_users where plant_id = p_plant limit 1;
  if acc is not null then
    perform net.http_post(
      url := fn_base || '/poll',
      headers := auth,
      body := jsonb_build_object('account', acc),
      timeout_milliseconds := 55000);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION private.first_load_continue()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  p bigint;
  rid bigint;                                                             -- 0235
  has_net boolean := to_regclass('net._http_response') is not null;      -- 0235
begin
  for p in
    -- SOLAR-378: up to 50 plants waiting for a refill, oldest first.
    with taken as (
      delete from private.refill_queue q
       where q.plant_id in (select plant_id from private.refill_queue
                             order by queued_at limit 50 for update skip locked)
      returning q.plant_id
    )
    select plant_id from taken
    union
    select pc.plant_id from public.plant_config pc
     where pc.backfill_next is not null
        or (pc.temp_next is not null and pc.temp_next < public.today_tz(coalesce(pc.timezone, 'Africa/Johannesburg')) - 1)
  loop
    -- 0235: the last run on this plant is still going.
    if has_net and exists (
         select 1 from private.recover_kicks k
          where k.plant_id = p and k.at > now() - interval '155 seconds'
            and not exists (select 1 from net._http_response r where r.id = k.request_id)) then
      -- A refill taken off the queue waits for the next turn, not the 6-hourly run.
      insert into private.refill_queue (plant_id) values (p) on conflict do nothing;
      continue;
    end if;
    rid := net.http_post(                                                 -- 0235: keep the id
      url := private.functions_url() || '/recover?plant=' || p,               -- 0280
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        'Content-Type', 'application/json'),
      body := '{}'::jsonb,
      timeout_milliseconds := 150000);
    insert into private.recover_kicks (plant_id, request_id) values (p, rid)   -- 0235
      on conflict (plant_id) do update set request_id = excluded.request_id, at = now();
  end loop;
end $function$;

create or replace function private.schedule_jobs()
 returns void
 language plpgsql
 set search_path to 'pg_temp'
as $function$
declare j record;
begin
  -- pg_cron keys a job by name and user: run as anyone else, every job would be made twice
  if current_user <> 'postgres' then
    raise exception 'run private.schedule_jobs() as postgres, not %', current_user using errcode = '42501';
  end if;
  for j in select * from (values
    ('agg-minute-rollup',    '40 4 * * *',         $c$select private.agg_minute_rollup(31)$c$),
    ('billing-delete',       '*/5 * * * *',        $c$select billing.delete_due()$c$),
    ('billing-history',      '* * * * *',          $c$select private.call_fn('recover?queue=1', '{}', 60000)$c$),
    ('billing-run',          '*/5 4-5 * * *',      $c$select private.call_fn('billing/run', '{}', 120000)$c$),
    ('ensure-partitions',    '0 3 * * *',          $c$select private.ensure_partitions()$c$),
    ('first-load-continue',  '*/2 * * * *',        $c$select private.first_load_continue()$c$),
    ('grid-off',             '10 4 * * *',         $c$select private.grid_off_update_all()$c$),
    ('history-delete',       '* * * * *',          $c$call private.history_delete_run()$c$),
    ('history-delete-slow',  '*/15 * * * *',       $c$call private.history_delete_check()$c$),
    ('job-check',            '2-59/5 * * * *',     $c$select private.call_fn('job-check', '{}', 30000)$c$),
    ('notify-email',         '* * * * *',          $c$select private.call_fn('notify-email', '{}', 55000)$c$),
    ('notify-push',          '* * * * *',          $c$select private.call_fn('notify-push', '{}', 55000)$c$),
    ('purge-cron-log',       '45 4 * * *',         $c$delete from cron.job_run_details where end_time < now() - make_interval(days => 7)$c$),
    ('rollup-old-days',      '*/5 5-7 * * *',      $c$call private.rollup_old_days(31)$c$),
    ('sunsynk-plant-energy', '15 2 * * *',         $c$select private.call_fn('sync-plant-energy', '{}', 150000)$c$),
    ('sunsynk-poll',         '* * * * *',          $c$select private.call_fn('poll', jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms), 55000) from private.poll_shards() s$c$),
    ('sunsynk-recover',      '5 4,10,16,22 * * *', $c$select private.call_fn('recover', '{}', 150000)$c$)
  ) t(name, sched, cmd) loop
    perform cron.schedule(j.name, j.sched, j.cmd);   -- by name: an existing job is updated in place
  end loop;
end $function$;
revoke all on function private.schedule_jobs() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- a database that runs jobs must know where its functions are: no secret, no migration
    perform private.functions_url();
    perform private.schedule_jobs();
  end if;
end $$;
