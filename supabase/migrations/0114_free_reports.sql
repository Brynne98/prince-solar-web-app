-- ============================================================================
-- 0114 — Free gets one report: the day-7 one (SOLAR-208, decided 2026-10-28).
--
-- A Free account with a free week on record (private.free_week_logins, 0110) gets
-- no weekly, monthly or yearly reports, from day 1. It gets two emails instead:
--   day 5  free_week_soon   "Your free week ends on Monday 12 Oct"
--   day 7  report_week      the week report with the free week ending (data
--                           freeWeekEnds), for the account's first active plant
-- Alerts carry on as before. An account with no free week on record (everyone from
-- before 0110) keeps its reports, as with the trim (0111).
--
-- The hold-back is in email_queue's insert trigger (0112), so the sweep's report
-- step needs no change. free_week_mail runs hourly; each email is keyed per user,
-- so it goes once, and only inside its day so a late first run doesn't send it weeks on.
-- ============================================================================

create or replace function private.email_skip_paused()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.plant_id is not null and exists (select 1 from public.plant_users pu
       where pu.user_id = new.user_id and pu.plant_id = new.plant_id and pu.paused) then
    return null;
  end if;
  -- Free with a free week on record: no reports but the day-7 one.
  if new.kind like 'report\_%' and not coalesce((new.data->>'freeWeekEnds')::boolean, false)
     and coalesce((select b.plan from private.billing b where b.user_id = new.user_id), 'free') = 'free'
     and exists (select 1 from private.free_week_logins f where f.user_id = new.user_id) then
    return null;
  end if;
  return new;
end $$;

create or replace function private.free_week_mail()
returns int
language plpgsql security definer set search_path = public, private, pg_temp
as $$
declare n int;
begin
  with fw as (
    select f.user_id, min(f.started_at) as started
      from private.free_week_logins f
      left join private.billing b on b.user_id = f.user_id
     where coalesce(b.plan, 'free') = 'free'
     group by f.user_id
  ), first_plant as (
    select distinct on (pu.user_id) pu.user_id, pu.plant_id
      from public.plant_users pu where not pu.paused
     order by pu.user_id, pu.linked_at, pu.plant_id
  )
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
  select fw.user_id, null, 'free_week_soon', 'free_week_soon:' || fw.user_id,
         jsonb_build_object('endsAt', extract(epoch from fw.started + interval '7 days')::bigint), 1
    from fw
   where now() >= fw.started + interval '5 days' and now() < fw.started + interval '6 days'
  union all
  select fw.user_id, fp.plant_id, 'report_week', 'report_week:free:' || fw.user_id,
         jsonb_build_object('today', timezone(public.plant_tz(fp.plant_id), now())::date, 'freeWeekEnds', true), 2
    from fw join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '7 days' and now() < fw.started + interval '8 days'
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function private.free_week_mail() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'free-week-mail') then
    perform cron.unschedule('free-week-mail');
  end if;
  perform cron.schedule('free-week-mail', '25 * * * *', 'select private.free_week_mail()');
end $$;
