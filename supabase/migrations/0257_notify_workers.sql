-- ============================================================================
-- 0257 — two senders: notify-email and notify-push (SOLAR-645 step 2).
--
-- One cron call (notify) did the sweeps, all emails, the billing outbox and the
-- pop-ups in 55 s. Pop-ups got what was left after 50 s; a slow Resend ate it.
-- Now:
--   notify-email  every minute: sweeps, then alert emails (priority 0), then the
--                 billing outbox, then the rest. One Resend pace for all three.
--   notify-push   every minute: pop-ups only, its own 55 s.
--
-- 1. email_claim takes a lane: 'urgent' = priority 0, 'bulk' = the rest, null = all
--    (the old notify still calls it without one). Body 0247, patched in place.
-- 2. job_check_push(): pop-ups due more than 5 minutes and not sent, for job-check.
-- 3. Cron: email-notify off, notify-email and notify-push on. The two functions must
--    be deployed before this runs. Back: unschedule both, schedule email-notify again
--    (0181's command).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. email_claim(p_limit, p_peek, p_lane)
-- ---------------------------------------------------------------------------
do $$
declare
  d text := pg_get_functiondef('public.email_claim(int, boolean)'::regprocedure);
  head text := 'public.email_claim(p_limit integer, p_peek boolean DEFAULT false)';
  old text := $o$           where q0.status = 'queued' and q0.due_at <= now()
$o$;
begin
  if position(head in d) = 0 or position(old in d) = 0 then
    raise exception 'email_claim changed since 0247: edit it by hand';
  end if;
  d := replace(d, head, 'public.email_claim(p_limit integer, p_peek boolean DEFAULT false, p_lane text DEFAULT NULL::text)');
  d := replace(d, old, old || $n$             and (p_lane is null or (p_lane = 'urgent') = (q0.priority = 0))   -- 0257
$n$);
  drop function public.email_claim(int, boolean);
  execute d;
end $$;
revoke all on function public.email_claim(int, boolean, text) from public, anon, authenticated;
grant execute on function public.email_claim(int, boolean, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Pop-ups waiting: alerts under an hour old (push_claim's own limit) with no
--    pop-up handled yet, queued more than 5 minutes ago.
-- ---------------------------------------------------------------------------
create or replace function public.job_check_push()
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('waiting', count(*), 'oldest', min(created_at))
    from public.email_queue
   where pushed_at is null and user_id is not null and private.is_alert(kind)
     and created_at > now() - interval '1 hour' and created_at <= now() - interval '5 minutes'
$$;
revoke all on function public.job_check_push() from public, anon, authenticated;
grant execute on function public.job_check_push() to service_role;

-- ---------------------------------------------------------------------------
-- 3. Cron
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - skipping notify jobs (expected on the local stack)';
    return;
  end if;
  perform cron.unschedule('email-notify') where exists (select 1 from cron.job where jobname = 'email-notify');
  perform cron.schedule('notify-email', '* * * * *', $c$select private.call_fn('notify-email', '{}', 55000)$c$);
  perform cron.schedule('notify-push', '* * * * *', $c$select private.call_fn('notify-push', '{}', 55000)$c$);
end $$;

notify pgrst, 'reload schema';
