-- ============================================================================
-- 0122 — the free week in the app and in two emails (SOLAR-242).
--
-- api_me says when a Free account's free week ends (freeWeekEndsAt, null for paid,
-- comped and accounts with no week on record), so the app can lock history after it.
--
-- free_week_mail (0114) gains a day-2 email, free_week_setup, sent only while setup
-- steps are left on the account's first plant; it lists those steps (the same four
-- as the app's First steps card, app.jsx firstSteps). The day-5 email now carries the
-- first plant, how many days of history it holds, and Home's yearly price per month,
-- so it can say what goes.
--
-- api_grid_off_recent gives Live's Free prompt the last grid-off span of the past day.
-- Paying again refetches a trimmed plant's 60 days (billing_refill_trimmed), so the
-- app's "your last 60 days come back" holds.
-- ============================================================================

create or replace function public.api_me()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'user', jsonb_build_object('id', auth.uid()),
    'plan', coalesce((select plan from private.billing where user_id = auth.uid()), 'free'),
    'freeWeekEndsAt', (select min(f.started_at) + interval '7 days' from private.free_week_logins f
                        where f.user_id = auth.uid()
                          and coalesce((select plan from private.billing where user_id = auth.uid()), 'free') = 'free'),
    'prefs', coalesce((select prefs from public.profiles where user_id = auth.uid()), '{}'::jsonb),
    'plants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pu.plant_id, 'name', pu.plant_name, 'linkedAt', pu.linked_at,
               'config', to_jsonb(c) - 'plant_id' - 'updated_by')
             order by pu.linked_at, pu.plant_id)
        from public.plant_users pu
        left join public.plant_config c on c.plant_id = pu.plant_id
       where pu.user_id = auth.uid() and not pu.paused), '[]'::jsonb))
$$;
revoke all on function public.api_me() from public, anon;
grant execute on function public.api_me() to authenticated, service_role;

-- Setup steps left on one plant, in the card's order. Mirrors app.jsx firstSteps: a
-- battery not yet detected counts as one; the reserve counts once confirmed (prefs)
-- or changed from 20; a plant marked done stays done.
create or replace function private.setup_steps_left(p_user uuid, p_plant bigint)
returns text[]
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select case when coalesce((m->>'done')::boolean, false) then '{}'::text[] else array_remove(array[
           case when not coalesce(c.tariff_import > 0, false) then 'rate' end,
           case when c.has_battery is distinct from false and not coalesce(c.battery_kwh > 0, false) then 'size' end,
           case when c.has_battery is distinct from false and not coalesce((m->>'reserve')::boolean, false)
                 and coalesce(c.battery_reserve_pct, 20) = 20 then 'reserve' end,
           case when not coalesce(c.system_kwp > 0, false) then 'panels' end], null) end
    from (select 1) one
    left join public.plant_config c on c.plant_id = p_plant
    left join lateral (
      select pr.prefs->'firstSteps'->(p_plant::text) as m
        from public.profiles pr where pr.user_id = p_user) p on true
$$;
revoke all on function private.setup_steps_left(uuid, bigint) from public, anon, authenticated;

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
  ), setup as (
    select fw.user_id, fp.plant_id, private.setup_steps_left(fw.user_id, fp.plant_id) as steps
      from fw join first_plant fp on fp.user_id = fw.user_id
     where now() >= fw.started + interval '2 days' and now() < fw.started + interval '3 days'
  )
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
  select s.user_id, s.plant_id, 'free_week_setup', 'free_week_setup:' || s.user_id,
         jsonb_build_object('steps', to_jsonb(s.steps)), 1
    from setup s
   where cardinality(s.steps) > 0
  union all
  select fw.user_id, fp.plant_id, 'free_week_soon', 'free_week_soon:' || fw.user_id,
         jsonb_build_object('endsAt', extract(epoch from fw.started + interval '7 days')::bigint,
           -- days with a total, before today: what the trim takes on the day the week ends
           'days', (select count(*) from public.plant_energy e
                     where e.plant_id = fp.plant_id and e.bucket = 'day'
                       and e.period < public.today_tz(public.plant_tz(fp.plant_id))),
           'perMonth', round(public.billing_amount('home', 'yearly') / 12.0)::int), 1
    from fw left join first_plant fp on fp.user_id = fw.user_id
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

-- The latest grid-off span that ended in the last 24 hours, for Free's "Grid was off"
-- prompt on Live. An open span (grid still off) is not one: the alert is still on.
create or replace function public.api_grid_off_recent(p_plant bigint default null)
returns jsonb
language sql stable security definer set search_path = public, pg_temp
as $$
  select jsonb_build_object('startedAt', g.started_at, 'endedAt', g.ended_at)
    from public.grid_off g
   where g.plant_id = public.my_plant(p_plant) and g.ended_at > now() - interval '24 hours'
   order by g.ended_at desc
   limit 1
$$;
revoke all on function public.api_grid_off_recent(bigint) from public, anon;
grant execute on function public.api_grid_off_recent(bigint) to authenticated, service_role;

-- "Upgrade and your last 60 days come back" (the app's day-8 card): a Free account that
-- starts paying gets its trimmed plants' 60 days fetched again, the same window a new
-- link gets (0044, 0046). free_trim (0111) only cleared these bookmarks; the plant is
-- no longer in free_trimmed_plants once paid, so recover walks them again.
create or replace function private.billing_refill_trimmed()
returns trigger
language plpgsql security definer set search_path = public, private, pg_temp
as $$
begin
  if new.plan = 'free' or (tg_op = 'UPDATE' and old.plan is not distinct from new.plan) then return new; end if;
  update public.plant_config c
     set backfill_next  = (now() at time zone c.timezone)::date - 60,
         backfill_until = (now() at time zone c.timezone)::date - 1,
         temp_next      = (now() at time zone c.timezone)::date - 60
   where c.plant_id in (select d.plant_id from private.free_trim_done d
                          join public.plant_users pu on pu.plant_id = d.plant_id
                         where pu.user_id = new.user_id);
  return new;
end $$;
revoke all on function private.billing_refill_trimmed() from public, anon, authenticated;
drop trigger if exists billing_refill_trimmed on private.billing;
create trigger billing_refill_trimmed after insert or update of plan on private.billing
  for each row execute function private.billing_refill_trimmed();
