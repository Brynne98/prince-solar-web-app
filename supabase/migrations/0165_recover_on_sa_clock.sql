-- ============================================================================
-- 0165 — the 6-hourly history refill runs on the South African clock (SOLAR-424).
--
-- sunsynk-recover ran at '17 */6 * * *' UTC (0009): 02:17, 08:17, 14:17, 20:17
-- SA time. Now 00:05, 06:05, 12:05, 18:05 SA time (UTC+2, no daylight saving).
-- The 5 minutes past let the slave's last 5-minute upload of the day land first.
-- Only the schedule changes; the job's command and timeout stay as they are.
-- ============================================================================

do $$
declare j bigint;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    return;
  end if;
  select jobid into j from cron.job where jobname = 'sunsynk-recover';
  if j is not null then
    perform cron.alter_job(j, schedule := '5 4,10,16,22 * * *');
  end if;
end $$;
