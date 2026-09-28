-- ============================================================================
-- 0062 — keep a week of pg_cron run history.
--
-- cron.job_run_details keeps a row for every run of every job and nothing ever
-- cleared it. With sunsynk-poll every minute and plant-purge every five, it had
-- reached 48 MB of the 500 MB database by 28 Sep, when it was truncated by hand.
-- This job was scheduled live the same day; the migration records it so a fresh
-- database gets it too. Re-running it replaces the job rather than adding a second.
-- Production only, as 0050: a no-op where pg_cron is absent.
-- ============================================================================
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping purge-cron-log schedule (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'purge-cron-log') then
    perform cron.unschedule('purge-cron-log');
  end if;
  perform cron.schedule('purge-cron-log', '45 4 * * *',
    $c$delete from cron.job_run_details where end_time < now() - make_interval(days => 7)$c$);
end $$;
