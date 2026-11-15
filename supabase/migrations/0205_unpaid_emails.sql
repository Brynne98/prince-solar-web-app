-- ============================================================================
-- 0205 — no alert or report for a plant that is not read, and two emails to an
--        account with no plan (SOLAR-552, decided by Brynne 2026-11-15).
--
-- Before: every account on a plant got its alerts. An account with no plan got no
-- report but the free week's last one (0114).
--
-- Now:
--   - email_queue's insert trigger drops an alert for a plant that is not read for
--     that account (plant_live, 0203). The pop-up and the app's list come from the
--     same row, so they stop too. Reports go to accounts with a plan only, as 0114
--     held them back; the free week's last report (day 7) still goes.
--   - unpaid_reminder, 14 days after the account stopped being paid for or free
--     (day 21 from the link), and unpaid_last, 27 days after (day 34, 3 days before
--     the delete). free_week_mail queues them, once per time the account lapses.
--     Both carry an unsubscribe link: the new email choice 'reminders'.
--   - The free week's emails and the win-back carry the delete date (30 days on).
-- ============================================================================

alter table public.email_prefs add column if not exists reminders boolean not null default true;

-- 0091's two functions, with 'reminders'.
create or replace function public.email_wanted(p_user uuid, p_kind text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare r public.email_prefs;
begin
  if p_kind not in ('weekly','monthly','yearly','grid','battery','panels','readings','sunsynk','reminders') then
    raise exception 'unknown email kind: %', p_kind;
  end if;
  select * into r from public.email_prefs where user_id = p_user;
  if not found then return true; end if;
  return case p_kind
    when 'weekly' then r.weekly     when 'monthly' then r.monthly   when 'yearly' then r.yearly
    when 'grid' then r.grid         when 'battery' then r.battery   when 'panels' then r.panels
    when 'readings' then r.readings when 'sunsynk' then r.sunsynk   when 'reminders' then r.reminders end;
end $$;

create or replace function public.email_unsubscribe(p_token uuid, p_kind text)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_kind not in ('weekly','monthly','yearly','grid','battery','panels','readings','sunsynk','reminders') then
    return false;
  end if;
  update public.email_prefs set
    weekly    = weekly    and p_kind <> 'weekly',
    monthly   = monthly   and p_kind <> 'monthly',
    yearly    = yearly    and p_kind <> 'yearly',
    grid      = grid      and p_kind <> 'grid',
    battery   = battery   and p_kind <> 'battery',
    panels    = panels    and p_kind <> 'panels',
    readings  = readings  and p_kind <> 'readings',
    sunsynk   = sunsynk   and p_kind <> 'sunsynk',
    reminders = reminders and p_kind <> 'reminders'
  where unsub_token = p_token;
  return found;
end $$;

-- 0151's email_switch, with the two reminders.
create or replace function private.email_switch(p_kind text)
returns text language sql immutable as $$
  select case
    when p_kind in ('grid_down', 'grid_back') then 'grid'
    when p_kind in ('batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back') then 'battery'
    when p_kind in ('string_dead', 'string_back') then 'panels'
    when p_kind in ('logger_stale', 'logger_back') then 'readings'
    when p_kind in ('sunsynk_down', 'sunsynk_back') then 'sunsynk'
    when p_kind = 'report_week' then 'weekly'
    when p_kind = 'report_month' then 'monthly'
    when p_kind = 'report_year' then 'yearly'
    when p_kind in ('unpaid_reminder', 'unpaid_last') then 'reminders'
  end
$$;

-- 0114's insert trigger: no mail for a locked plant, no report without a plan, and
-- no alert for a plant that is not read for this account.
create or replace function private.email_skip_paused()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.plant_id is not null and exists (select 1 from public.plant_users pu
       where pu.user_id = new.user_id and pu.plant_id = new.plant_id and pu.paused) then
    return null;
  end if;
  -- No plan: no report but the free week's last one (0114), in the week too.
  if new.kind like 'report\_%' and not coalesce((new.data->>'freeWeekEnds')::boolean, false)
     and coalesce((select b.plan from private.billing b where b.user_id = new.user_id), 'free') = 'free' then
    return null;
  end if;
  -- An alert for a plant that is not read for this account.
  if new.plant_id is not null and new.user_id is not null and private.is_alert(new.kind)
     and not private.plant_live(new.user_id, new.plant_id) then
    return null;
  end if;
  return new;
end $$;

-- 0188's winback, with the day the history is deleted.
create or replace function private.billing_winback()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (new.user_id, 'winback', 'winback:' || old.next_billing_date,
          jsonb_build_object('from', old.plan, 'deleteOn', private.billing_today() + 30,
            'days', (select count(*) from public.plant_energy e
                      where e.bucket = 'day'
                        and e.plant_id = (select pu.plant_id from public.plant_users pu
                                           where pu.user_id = new.user_id and not pu.paused
                                             and pu.plant_id <> all (coalesce(old.plants_to_remove, '{}'))
                                           order by array_position(old.next_keep, pu.plant_id) nulls last, pu.linked_at, pu.plant_id
                                           limit 1))), 1)
  on conflict do nothing;
  return null;
end $$;
revoke all on function private.billing_winback() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 0182's free_week_mail. Added: the two reminders, by unpaid_since (0203), for an
-- account that still runs a plant. The day-7 report counts every day total, since
-- nothing is trimmed, and carries the delete date.
-- ---------------------------------------------------------------------------
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
  ), unpaid as (
    select f.user_id, private.unpaid_since(f.user_id) as since
      from private.free_week_logins f
     where exists (select 1 from public.plant_users pu where pu.user_id = f.user_id and not pu.paused)
  )
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
  select s.user_id, s.plant_id, 'free_week_setup', 'free_week_setup:' || s.user_id,
         jsonb_build_object('steps', to_jsonb(s.steps), 'battery', s.battery), 1
    from setup s
   where cardinality(s.steps) > 0
  union all
  select fw.user_id, fp.plant_id, 'free_week_soon', 'free_week_soon:' || fw.user_id,
         jsonb_build_object('endsAt', extract(epoch from fw.started + interval '7 days')::bigint,
           -- days with a total, before today
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
           'deleteOn', timezone(public.plant_tz(fp.plant_id), fw.started + interval '37 days')::date,
           'days', (select count(*) from public.plant_energy e
                     where e.plant_id = fp.plant_id and e.bucket = 'day'
                       and e.period < public.today_tz(public.plant_tz(fp.plant_id)))), 2
    from fw join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '7 days' and now() < fw.started + interval '8 days'
  union all
  select u.user_id, null, k.kind, k.kind || ':' || u.user_id || ':' || u.since::date,
         jsonb_build_object('since', extract(epoch from u.since)::bigint,
           'deleteAt', extract(epoch from u.since + interval '30 days')::bigint,
           'plants', (select count(*) from private.plant_picks p where p.user_id = u.user_id)), 1
    from unpaid u
   cross join (values ('unpaid_reminder', 14), ('unpaid_last', 27)) k(kind, day)
   where now() >= u.since + make_interval(days => k.day) and now() < u.since + make_interval(days => k.day + 1)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function private.free_week_mail() from public, anon, authenticated;

notify pgrst, 'reload schema';
