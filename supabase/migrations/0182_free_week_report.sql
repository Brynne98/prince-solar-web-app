-- ============================================================================
-- 0182 — the day-7 report covers the free week and comes before the trim (SOLAR-475).
--
-- The day-7 report was queued at :25, but the hourly trim (:20) usually ran first and
-- left only today's and yesterday's day totals. The report covered the last Monday to
-- Sunday, so it came out near empty or not at all.
--
-- Now the report row carries the free week's first day (from) and the day totals the
-- trim deletes (days), counted when the row is queued. notify reports from that day for
-- 7 days. The trim waits one hour past the week's end, so the report is built first:
-- the row is queued within the hour after the end, and notify sends it within minutes.
-- ============================================================================

create or replace function public.free_trimmed_plants()
returns setof bigint
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select pu.plant_id
    from public.plant_users pu
    left join private.billing b on b.user_id = pu.user_id
    left join lateral (select min(started_at) as started from private.free_week_logins f
                        where f.user_id = pu.user_id) fw on true
   group by pu.plant_id
  having bool_and(coalesce(b.plan, 'free') = 'free' and fw.started is not null
                  and fw.started < now() - interval '7 days 1 hour'
                  and (b.keep_until is null or b.keep_until < private.billing_today()))
$$;

create or replace function private.free_week_mail()
returns int language plpgsql security definer set search_path = public, private, pg_temp as $$
declare n int;
begin
  with fw as (
    select f.user_id, min(f.started_at) as started
      from private.free_week_logins f
      left join private.billing b on b.user_id = f.user_id
     where coalesce(b.plan, 'free') = 'free'
     group by f.user_id
  ), first_plant as (
    select distinct on (pu.user_id) pu.user_id, pu.plant_id, pu.linked_at
      from public.plant_users pu where not pu.paused
     order by pu.user_id, pu.linked_at, pu.plant_id
  ), setup as (
    -- Day 2 after the account's first plant, on any plan; Hide on the app's card doesn't stop it.
    select fp.user_id, fp.plant_id, private.setup_steps_open(fp.plant_id) as steps,
           c.has_battery is distinct from false as battery
      from first_plant fp left join public.plant_config c on c.plant_id = fp.plant_id
     where now() >= fp.linked_at + interval '2 days' and now() < fp.linked_at + interval '3 days'
  )
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
  select s.user_id, s.plant_id, 'free_week_setup', 'free_week_setup:' || s.user_id,
         jsonb_build_object('steps', to_jsonb(s.steps), 'battery', s.battery), 1
    from setup s
   where cardinality(s.steps) > 0
  union all
  select fw.user_id, fp.plant_id, 'free_week_soon', 'free_week_soon:' || fw.user_id,
         jsonb_build_object('endsAt', extract(epoch from fw.started + interval '7 days')::bigint,
           -- days with a total, before today: what the trim takes on the day the week ends
           'days', (select count(*) from public.plant_energy e
                     where e.plant_id = fp.plant_id and e.bucket = 'day'
                       and e.period < public.today_tz(public.plant_tz(fp.plant_id))),
           'perMonth', round(public.billing_amount('home', 'yearly', 0,
                         private.billing_offer_open(fw.user_id, private.billing_today())) / 12.0)::int), 1
    from fw left join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '5 days' and now() < fw.started + interval '6 days'
  union all
  select fw.user_id, fp.plant_id, 'report_week', 'report_week:free:' || fw.user_id,
         jsonb_build_object('today', timezone(public.plant_tz(fp.plant_id), now())::date, 'freeWeekEnds', true,
           'from', timezone(public.plant_tz(fp.plant_id), fw.started)::date,
           -- day totals the trim deletes: all but today and yesterday
           'days', (select count(*) from public.plant_energy e
                     where e.plant_id = fp.plant_id and e.bucket = 'day'
                       and e.period < public.today_tz(public.plant_tz(fp.plant_id)) - 1)), 2
    from fw join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '7 days' and now() < fw.started + interval '8 days'
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
