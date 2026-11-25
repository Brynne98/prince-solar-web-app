-- ============================================================================
-- 0271 — the billing cron jobs on every database (SOLAR-666).
--
-- billing.switch_on and billing.start_delete_job scheduled billing-history and billing-delete
-- (0246). On a database built from migrations 0252 switches billing on without them, so those
-- two jobs never existed there. Production got them from the real switch-over.
--   1. billing-run, billing-history, billing-delete: a matching job is left alone, a changed
--      schedule or command is set back in place (same job id: job_check_inputs joins run
--      history on it, 0180; a paused job stays paused), a missing one is made. No change
--      on production.
--   2. switch_on and start_delete_job go: one-off switch-over steps, done; switch_on writes
--      billing.old_jobs, which 0252 dropped. delete_due writes the first 'delete' heartbeat.
-- ============================================================================

do $$
declare
  j record;
  id bigint;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping billing jobs (expected on the local stack)';
    return;
  end if;
  for j in select * from (values
      ('billing-delete', '*/5 * * * *', 'select billing.delete_due()', false),
      ('billing-history', '* * * * *', $c$select private.call_fn('recover?queue=1', '{}', 60000)$c$, true),
      -- billing.next_run_at (0254) reads this schedule: change both together
      ('billing-run', '*/5 4-5 * * *', $c$select private.call_fn('billing/run', '{}', 120000)$c$, true)
    ) as v(name, schedule, command, needs_net)
  loop
    if j.needs_net and not exists (select 1 from pg_extension where extname = 'pg_net') then
      raise notice 'pg_net not enabled here - skipping %', j.name;
      continue;
    end if;
    select jobid into id from cron.job where jobname = j.name and username = current_user;
    if id is null then
      perform cron.schedule(j.name, j.schedule, j.command);
    elsif not exists (select 1 from cron.job where jobid = id and schedule = j.schedule and command = j.command) then
      -- a job paused by hand stays paused
      perform cron.alter_job(job_id := id, schedule := j.schedule, command := j.command);
    end if;
  end loop;
end $$;

drop function billing.switch_on(timestamptz);
drop function billing.start_delete_job();
