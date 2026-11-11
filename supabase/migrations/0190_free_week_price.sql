-- ============================================================================
-- 0190 — the free-week notice quotes the email's price (SOLAR-503).
--
-- 0176's free_week_soon gave perMonth as Home's yearly price / 12 (R41 at launch, R83 at
-- list), while the email says Home's monthly price (R49, "the launch price"). perMonth is
-- now Home's monthly price at the account's offer, and list the usual monthly price, both
-- as email_prices (0169) reads them. Otherwise 0176's billing_notices unchanged.
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
    -- room: the plants the plan covers from that date (a booked change, else today's plan)
    out := out || jsonb_build_object('kind', 'bill_removal_soon', 'on', b.remove_on,
      'room', coalesce(private.billing_next_room(b), public.billing_room(b.plan, b.extra_plants)),
      'plants', coalesce((select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                   from plant_users pu where pu.user_id = me and pu.plant_id = any (b.plants_to_remove)), '[]'));
  end if;

  -- after a failed payment only (bill_free's email), not a cancel that ended (winback)
  if b.plan = 'free' and exists (select 1 from email_queue q where q.user_id = me and q.kind = 'bill_free'
                                   and q.created_at > now() - interval '30 days') then
    out := out || jsonb_build_object('kind', 'bill_free', 'deleteOn', b.remove_on,
      'kept', (select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                 from plant_users pu where pu.user_id = me and not pu.paused),
      'stopped', (select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                    from plant_users pu where pu.user_id = me and pu.plant_id = any (coalesce(b.plants_to_remove, '{}'))));
  end if;

  -- a paid switch to yearly (prepaid_on, 0138) has nothing to undo; a cancel in it does (SOLAR-467)
  if b.plan <> 'free' and not b.comped and b.state = 'active' and booked
     and (b.prepaid_on is null or b.next_plan = 'free') then
    out := out || jsonb_build_object('kind', 'bill_change',
      'on', case when b.prepaid_on is not null then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                 else b.next_billing_date end,
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
        'perMonth', (private.billing_price_list(private.billing_offer_now(me)) #>> '{monthly,home}')::int,
        'list', (private.billing_price_list(null) #>> '{monthly,home}')::int);
    elsif now() >= started + interval '7 days' and now() < started + interval '14 days' then
      out := out || jsonb_build_object('kind', 'free_week_ended');
    end if;
  end if;

  return out;
end $$;
revoke all on function private.billing_notices() from public, anon, authenticated;
