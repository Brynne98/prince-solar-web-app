CREATE OR REPLACE FUNCTION private.schedule_jobs()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'pg_temp'
AS $function$
declare j record;
begin
  -- pg_cron keys a job by name and user: run as anyone else, every job would be made twice
  if current_user <> 'postgres' then
    raise exception 'run private.schedule_jobs() as postgres, not %', current_user using errcode = '42501';
  end if;
  for j in select * from (values
    ('agg-minute-rollup',    '40 4 * * *',         $c$select private.agg_minute_rollup(31)$c$),
    ('alerts',               '* * * * *',          $c$select private.alerts_minute()$c$),
    ('plant-check',          '* * * * *',          $c$select private.plant_checks()$c$),
    ('plant-sync',           '* * * * *',          $c$select private.call_fn('poll', '{"task":"sync"}', 55000)$c$),
    ('temps',                '* * * * *',          $c$select private.call_fn('poll', '{"task":"temps"}', 55000)$c$),
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
    ('plant-energy',         '15 2 * * *',         $c$select private.call_fn('sync-plant-energy', '{}', 150000)$c$),
    ('reader',               '* * * * *',          $c$select private.call_fn('poll', jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms), 55000) from private.poll_shards() s$c$),
    ('recover',              '5 4,10,16,22 * * *', $c$select private.call_fn('recover', '{}', 150000)$c$)
  ) t(name, sched, cmd) loop
    perform cron.schedule(j.name, j.sched, j.cmd);   -- by name: an existing job is updated in place
  end loop;
  -- the names before SOLAR-681 R16: gone, so no job runs twice
  perform cron.unschedule(jobname) from cron.job where jobname in ('sunsynk-poll', 'sunsynk-recover', 'sunsynk-plant-energy');
end $function$;
