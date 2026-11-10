-- SOLAR-467: a booked cancel can be undone until the plan ends.
-- Decided by Brynne 2026-11-10: paid changes are final; booked changes can be undone until
-- their date. A cancel books nothing paid, so Keep <plan> undoes it, as for a downgrade. In a
-- paid year (0138, prepaid_on) the undo goes back to the paid switch to yearly, which stays.
-- While a cancel is booked the plan still buys nothing more and takes no other change
-- (0175): Keep first. Account delete stays allowed while a cancel is booked.

-- 0175's guard: a cancel may be undone. A paid year still takes only a cancel or its undo.
create or replace function private.billing_year_paid_guard()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  if new.plan = 'free' or new.comped then
    new.prepaid_on := null;
    return new;
  end if;
  if old.prepaid_on is not null and new.prepaid_on is not null
     and ((new.plan, new.period, new.extra_plants, new.next_period, new.next_extra_plants)
            is distinct from (old.plan, old.period, old.extra_plants, old.next_period, old.next_extra_plants)
          or (new.next_plan is distinct from old.next_plan and new.next_plan is not null and new.next_plan <> 'free')) then
    raise exception 'your year is paid: the plan stays until it starts' using errcode = '22023';
  end if;
  return new;
end $$;

-- 0175's booking: a cancel is undone by booking the plan it cancels; nothing else until then.
create or replace function public.billing_book_change(p_user uuid, p_plan text, p_period text default null,
  p_keep bigint[] default null)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  rank constant jsonb := '{"free": 0, "home": 1, "family": 2}';
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' then
    raise exception 'nothing to change on Free' using errcode = '22023';
  end if;
  if b.comped then
    raise exception 'this plan is free of charge' using errcode = '22023';
  end if;
  if b.prepaid_on is not null then
    -- a paid year: a cancel, or its undo back to the paid switch (SOLAR-467)
    if p_plan = b.plan then
      update private.billing set next_plan = null, next_keep = '{}', updated_at = now()
       where user_id = p_user and next_plan = 'free';
      return;
    end if;
    if p_plan <> 'free' then
      raise exception 'your year is paid: the plan stays until it starts' using errcode = '22023';
    end if;
    update private.billing
       set next_plan = 'free', next_keep = private.billing_keep_list(p_user, p_keep), updated_at = now()
     where user_id = p_user;
    return;
  end if;
  -- a booked cancel: only its undo, the plan as it is (SOLAR-467)
  if b.next_plan = 'free' and not (p_plan = b.plan and coalesce(p_period, b.period) = b.period) then
    raise exception 'your plan is cancelled: keep it first' using errcode = '22023';
  end if;
  if (rank->>p_plan)::int > (rank->>b.plan)::int then
    raise exception 'an upgrade starts at once, not at the billing date' using errcode = '22023';
  end if;
  if p_plan = b.plan and b.period = 'monthly' and p_period = 'yearly' then
    raise exception 'a switch to yearly is paid now, not booked' using errcode = '22023';
  end if;
  update private.billing
     set next_plan   = case when p_plan = b.plan then null else p_plan end,
         next_period = case when p_plan = 'free' or coalesce(p_period, b.period) = b.period then null
                            else p_period end,
         -- a new plan: the pick given (none: the first linked); a period switch or undo: the pick held
         -- a plan change or an undo takes a booked extras drop with it: one change (SOLAR-364)
         next_extra_plants = case when p_plan <> b.plan or coalesce(p_period, b.period) = b.period then null
                                  else next_extra_plants end,
         next_keep   = case when p_plan = b.plan and p_keep is null
                              then case when coalesce(p_period, b.period) = b.period or b.next_extra_plants is null then '{}' else next_keep end
                            else private.billing_keep_list(p_user, p_keep) end,
         updated_at  = now()
   where user_id = p_user;
end $$;

-- 0175's change: an undone cancel in a paid year is emailed as kept, with the payment after
-- that year. The paid switch alone is not a booked change to undo.
create or replace function public.api_billing_change(p_plan text, p_period text default null, p_keep bigint[] default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing; was_booked boolean; drops bigint[];
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  -- for update: a double tap undoes once and emails once
  select next_plan is not null or (next_period is not null and prepaid_on is null) into was_booked
    from private.billing where user_id = auth.uid() for update;
  perform public.billing_book_change(auth.uid(), p_plan, p_period, p_keep);
  select * into b from private.billing where user_id = auth.uid();
  drops := private.billing_drops(b);
  if b.next_plan is not null or (b.next_period is not null and b.prepaid_on is null) then
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (auth.uid(), 'bill_change', 'bill_change:' || gen_random_uuid(),
            jsonb_build_object('from', b.plan, 'to', coalesce(b.next_plan, b.plan),
              'fromPeriod', b.period, 'toPeriod', coalesce(b.next_period, b.period),
              -- a cancel in a paid year ends when that year does (SOLAR-457)
              'on', case when b.prepaid_on is not null then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                         else b.next_billing_date end,
              'nextAmount', case when coalesce(b.next_plan, b.plan) <> 'free' then public.billing_amount_due(auth.uid()) end,
              'deleteOn', case when cardinality(drops) > 0 then b.next_billing_date + 30 end,
              'removePlants', coalesce((select jsonb_agg(pu.plant_name order by pu.linked_at) from public.plant_users pu
                                         where pu.user_id = auth.uid() and pu.plant_id = any (drops)), '[]'::jsonb)),
            1);
  elsif was_booked then
    -- in a paid year the next payment is the year after the paid one (SOLAR-467)
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (auth.uid(), 'bill_kept', 'bill_kept:' || gen_random_uuid(),
            jsonb_build_object('plan', b.plan, 'period', coalesce(b.next_period, b.period),
              'on', case when b.prepaid_on is not null then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                         else b.next_billing_date end,
              'nextAmount', public.billing_amount_due(auth.uid())),
            1);
  end if;
  return public.api_billing_status();
end $$;

-- 0148's notices: a cancel in a paid year shows in the bell too, with its undo and the day
-- that year ends. The paid switch alone still has nothing to undo.
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
        'perMonth', round(public.billing_amount('home', 'yearly', 0, private.billing_offer_open(me, today)) / 12.0)::int);
    elsif now() >= started + interval '7 days' and now() < started + interval '14 days' then
      out := out || jsonb_build_object('kind', 'free_week_ended');
    end if;
  end if;

  return out;
end $$;
revoke all on function private.billing_notices() from public, anon, authenticated;
