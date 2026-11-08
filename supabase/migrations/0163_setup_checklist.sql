-- ============================================================================
-- 0163 — the setup email goes to every account, as a checklist (SOLAR-415).
--
-- free_week_setup was sent on day 2 of the free week, to Free accounts only, and not
-- once the app's setup card was hidden. Now it goes 2 days after the account's first
-- plant is linked, on any plan, hidden card or not, while a number is still empty.
-- Its data says whether the plant has a battery, so the email can tick what is set
-- and leave out the battery rows on a plant without one.
--
-- setup_steps_open is the plant half of setup_steps_left (what is still empty);
-- setup_steps_left keeps the Hide check for the app.
-- ============================================================================

create or replace function private.setup_steps_open(p_plant bigint)
returns text[]
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select array_remove(array[
           case when not coalesce(c.tariff_import > 0, false) then 'rate' end,
           case when c.has_battery is distinct from false and not coalesce(c.battery_kwh > 0, false) then 'size' end,
           case when c.has_battery is distinct from false and not coalesce(c.battery_reserve_confirmed, false)
                 and coalesce(c.battery_reserve_pct, 20) = 20 then 'reserve' end,
           case when not coalesce(c.system_kwp > 0, false) then 'panels' end], null)
    from (select 1) one
    left join public.plant_config c on c.plant_id = p_plant
$$;
revoke all on function private.setup_steps_open(bigint) from public, anon, authenticated;

create or replace function private.setup_steps_left(p_user uuid, p_plant bigint)
returns text[]
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select case when coalesce((p.m->>'done')::boolean, false) then '{}'::text[] else private.setup_steps_open(p_plant) end
    from (select 1) one
    left join lateral (
      select pr.prefs->'firstSteps'->(p_plant::text) as m
        from public.profiles pr where pr.user_id = p_user) p on true
$$;
revoke all on function private.setup_steps_left(uuid, bigint) from public, anon, authenticated;

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
         jsonb_build_object('today', timezone(public.plant_tz(fp.plant_id), now())::date, 'freeWeekEnds', true), 2
    from fw join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '7 days' and now() < fw.started + interval '8 days'
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
