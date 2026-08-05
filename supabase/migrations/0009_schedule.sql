-- ============================================================================
-- Scheduled jobs. This is what replaces the monolith's timers:
--
--   setInterval(tick, 60_000)          ->  sunsynk-poll          every minute
--   setInterval(recoverAllGaps, 6h)    ->  sunsynk-recover       every 6 hours
--   (getEnergy/getCompare, per request)->  sunsynk-plant-energy  daily 02:15 UTC
--
-- ---------------------------------------------------------------------------
-- PRODUCTION-ONLY BY CONSTRUCTION.
--
-- This file hardcodes a project ref, so applying it to the local stack would
-- register jobs that POST at production every minute. The guard below makes it a
-- no-op wherever pg_cron isn't already enabled — which is the local stack, since
-- `supabase start` doesn't enable it. Local development invokes the functions by
-- hand instead. Do not "fix" this by adding CREATE EXTENSION.
--
-- Two one-time steps in the dashboard before this does anything:
--
--   1. Database > Extensions: enable `pg_cron` and `pg_net`
--   2. SQL editor:
--        select vault.create_secret('<YOUR_SECRET_KEY>', 'service_role_key');
--      Use the sb_secret_... key from Settings > API. The key must never be
--      written into a migration — these are committed to a public repo.
--
-- Until the Vault secret exists the jobs run and fail with 401. Nothing else
-- breaks, and no data is lost: `recover` backfills any missed minutes from
-- SunSynk's cloud once the schedule is working.
-- ============================================================================

do $$
declare
  fn_base text := 'https://pmakzojwhouamawgszrc.functions.supabase.co';
  auth_hdr text := $hdr$jsonb_build_object(
                     'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
                     'Content-Type', 'application/json')$hdr$;
  j text;
  spec record;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - skipping schedule (expected on the local stack)';
    return;
  end if;

  -- re-running must not stack duplicate jobs
  foreach j in array array['sunsynk-poll', 'sunsynk-recover', 'sunsynk-plant-energy'] loop
    if exists (select 1 from cron.job where jobname = j) then
      perform cron.unschedule(j);
    end if;
  end loop;

  for spec in
    select * from (values
      -- the logger
      ('sunsynk-poll',         '* * * * *',   'poll',              50000),
      -- bank logger-offline minutes well before the cloud drops them (~1-2 weeks)
      ('sunsynk-recover',      '17 */6 * * *', 'recover',          150000),
      -- plant totals only move for the current day/month; 02:15 UTC = 04:15 local
      ('sunsynk-plant-energy', '15 2 * * *',  'sync-plant-energy', 150000)
    ) as t(jobname, sched, fn, timeout_ms)
  loop
    perform cron.schedule(spec.jobname, spec.sched, format(
      'select net.http_post(url := %L, headers := %s, body := %L::jsonb, timeout_milliseconds := %s);',
      fn_base || '/' || spec.fn, auth_hdr, '{}', spec.timeout_ms));
  end loop;

  raise notice 'scheduled sunsynk-poll, sunsynk-recover, sunsynk-plant-energy';
end $$;
