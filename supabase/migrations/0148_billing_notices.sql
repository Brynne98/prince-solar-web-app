-- ============================================================================
-- 0148 — Billing notices in the app (SOLAR-212).
--
-- api_notifications' pinned slot (0124) gets the billing and plan messages that
-- otherwise go only by email. Each is read from the state as it is now, so it shows
-- while the state lasts and goes when it ends; nothing is stored. The app writes the
-- words (the emails' words, in app.jsx), from these facts:
--
--   bill_failed          past due: amount, nextTry (null after the last try), freeOn
--   bill_removal_soon    plants deleted within 3 days, as bill_removal_soon's email
--   bill_free            a paid plan moved to Free, while readings are still kept
--                        (keep_until, 0146): kept and stopped plants, deleteOn
--   bill_change          a change booked for the billing date (cancel, downgrade,
--                        monthly/yearly switch, fewer extra plants): what undoes it
--   bill_renewal_notice  yearly, up to 60 days before the date, as its email; not
--                        while a change is booked (bill_change says it)
--   free_week_soon       day 5 to 7 of the free week, as free_week_soon's email
--   free_week_ended      day 7 to 14 after it began
--
-- Order is urgency: the app shows the first two as a banner on every page too.
-- ============================================================================

create or replace function private.billing_notices()
returns jsonb language plpgsql stable set search_path = public, private, pg_temp as $$
declare
  me uuid := auth.uid();
  b private.billing;
  today date := private.billing_today();
  st jsonb;
  started timestamptz;
  first_plant bigint;
  out jsonb := '[]';
  booked boolean;
begin
  select * into b from private.billing where user_id = me;
  booked := b.next_plan is not null or b.next_period is not null or b.next_extra_plants is not null;

  if b.state = 'past_due' and b.plan <> 'free' then
    -- the same next try and Free date as Billing shows
    st := public.api_billing_status();
    out := out || jsonb_build_object('kind', 'bill_failed', 'plan', b.plan, 'amount', st->'nextAmount',
                                     'nextTry', st->'nextTry', 'freeOn', st->'freeOn');
  end if;

  if b.remove_on > today and b.remove_on <= today + 3 and cardinality(b.plants_to_remove) > 0 then
    out := out || jsonb_build_object('kind', 'bill_removal_soon', 'on', b.remove_on,
      'plants', (select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                   from plant_users pu where pu.user_id = me and pu.plant_id = any (b.plants_to_remove)));
  end if;

  if b.plan = 'free' and b.keep_until >= today then
    out := out || jsonb_build_object('kind', 'bill_free', 'deleteOn', b.remove_on,
      'kept', (select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                 from plant_users pu where pu.user_id = me and not pu.paused),
      'stopped', (select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                    from plant_users pu where pu.user_id = me and pu.plant_id = any (coalesce(b.plants_to_remove, '{}'))));
  end if;

  -- a paid switch to yearly (prepaid_on, 0138) has nothing to undo
  if b.plan <> 'free' and not b.comped and b.state = 'active' and booked and b.prepaid_on is null then
    out := out || jsonb_build_object('kind', 'bill_change', 'on', b.next_billing_date,
      'plan', b.plan, 'period', b.period, 'nextPlan', b.next_plan, 'nextPeriod', b.next_period,
      'extraPlants', coalesce(b.extra_plants, 0), 'nextExtraPlants', b.next_extra_plants);
  end if;

  if b.period = 'yearly' and not b.comped and b.state = 'active' and not booked
     and b.next_billing_date > today and b.next_billing_date <= today + 60 then
    out := out || jsonb_build_object('kind', 'bill_renewal_notice', 'plan', b.plan, 'on', b.next_billing_date,
                                     'amount', public.billing_amount_due(me));
  end if;

  -- the free week: never paid, as free_week_mail (0145) reads it
  if coalesce(b.plan, 'free') = 'free' and not coalesce(b.comped, false) and b.keep_until is null then
    select min(f.started_at) into started from private.free_week_logins f where f.user_id = me;
    if now() >= started + interval '5 days' and now() < started + interval '7 days' then
      select pu.plant_id into first_plant from plant_users pu where pu.user_id = me and not pu.paused
       order by pu.linked_at, pu.plant_id limit 1;
      out := out || jsonb_build_object('kind', 'free_week_soon',
        'endsAt', started + interval '7 days',
        'plant', (select coalesce(pu.plant_name, 'Plant ' || pu.plant_id) from plant_users pu
                   where pu.user_id = me and pu.plant_id = first_plant),
        'days', (select count(*) from plant_energy e
                  where e.plant_id = first_plant and e.bucket = 'day'
                    and e.period < public.today_tz(public.plant_tz(first_plant))),
        'perMonth', round(public.billing_amount('home', 'yearly', 0, private.billing_offer_open(me, today)) / 12.0)::int);
    elsif now() >= started + interval '7 days' and now() < started + interval '14 days' then
      out := out || jsonb_build_object('kind', 'free_week_ended');
    end if;
  end if;

  return out;
end $$;
revoke all on function private.billing_notices() from public, anon, authenticated;

-- 0124's list, with the pinned notices.
create or replace function public.api_notifications()
returns jsonb language sql stable security definer set search_path = '' as $$
  with n as (
    select q.id, q.kind, q.plant_id, pu.plant_name, q.read_at, q.created_at,
           private.alert_text(q.kind, q.data, q.created_at, public.plant_tz(q.plant_id)) t
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid()
       and q.kind in ('grid_down', 'grid_back', 'batt_hot', 'bank_drift', 'string_dead',
                      'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back')
       and q.created_at > now() - interval '30 days'
     order by q.created_at desc, q.id desc
     limit 300)
  select jsonb_build_object(
    'pinned', private.billing_notices(),
    'unread', (select count(*) from n where read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'plant', plant_id, 'plantName', plant_name, 'read', read_at is not null) || t
        order by created_at desc, id desc) from n), '[]'::jsonb));
$$;
