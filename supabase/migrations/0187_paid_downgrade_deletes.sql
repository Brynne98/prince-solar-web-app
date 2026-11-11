-- ============================================================================
-- 0187 — a smaller paid plan deletes its stopped plants on the billing date (SOLAR-492).
--
-- Brynne 2026-11-11: the 30 days a stopped plant's history is kept are for a move to Free
-- (a cancel, 0146 and the winback email 0144) and for a failed payment's move to Free, to
-- give a reason to come back. A downgrade to a smaller paid plan (Family to Home, or fewer
-- extra plants) is the user's choice: its stopped plants are deleted on the billing date.
-- Turning a plant off on a plan that stays is unchanged (deleted at once, 0125).
--
-- billing_renew drops a paid change's stopped plants when it runs; api_link_status and the
-- booking email date their deletion on that day, not 30 days on.
-- ============================================================================

-- 0175's renewal, with a paid change's stopped plants dropped on the day.
create or replace function public.billing_renew(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  due int;
  v_plan text; v_period text;
  going bigint[];
  keep bigint[];
  before bigint[];
  stopped bigint[];
  p bigint;
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' or b.comped then
    raise exception 'nothing to renew on Free' using errcode = '22023';
  end if;
  -- a switch paid this date's year already (0138)
  due := case when b.prepaid_on = b.next_billing_date then 0 else public.billing_amount_due(p_user) end;
  -- A cancel booked in a paid year (SOLAR-457): the year starts as paid; the cancel waits for its end.
  if b.prepaid_on = b.next_billing_date and b.next_plan = 'free' then
    update private.billing
       set period = 'yearly',
           next_billing_date = public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1),
           extra_plants = case when b.plan = 'family' then coalesce(b.next_extra_plants, b.extra_plants) else 0 end,
           next_period = null, next_extra_plants = null, prepaid_on = null, updated_at = now()
     where user_id = p_user;
    return jsonb_build_object('charge', 0, 'plan', b.plan, 'removePlants', '[]'::jsonb, 'stopped', '[]'::jsonb);
  end if;
  v_plan := coalesce(b.next_plan, b.plan);
  v_period := coalesce(b.next_period, b.period);
  going := case when b.remove_on <= b.next_billing_date then b.plants_to_remove else '{}' end;
  -- the plants the booked plan keeps: those that do not stop (0136)
  select coalesce(array_agg(plant_id order by array_position(b.next_keep, plant_id) nulls last, linked_at, plant_id), '{}')
    into keep from public.plant_users
   where user_id = p_user and not paused and plant_id <> all (coalesce(b.plants_to_remove, '{}'))
     and plant_id <> all (private.billing_drops(b));
  select coalesce(array_agg(plant_id), '{}') into before from public.plant_users where user_id = p_user and not paused;
  update private.billing
     set plan = v_plan,
         period = case when v_plan = 'free' then null else v_period end,
         billing_day = case when v_plan = 'free' then null else b.billing_day end,
         next_billing_date = case when v_plan = 'free' then null
                             else public.billing_step(b.next_billing_date, v_period, b.billing_day, 1) end,
         extra_plants = case when v_plan = 'family' then coalesce(b.next_extra_plants, b.extra_plants) else 0 end,
         next_plan = null, next_period = null, next_extra_plants = null, next_keep = '{}', prepaid_on = null,
         updated_at = now()
   where user_id = p_user;
  -- booked for deletion last, then the pick
  perform private.billing_fit(p_user, coalesce(b.plants_to_remove, '{}'), keep);
  select coalesce(array_agg(plant_id order by plant_id), '{}') into stopped from public.plant_users
   where user_id = p_user and paused and plant_id = any (before) and plant_id <> all (coalesce(b.plants_to_remove, '{}'));
  -- stopped by the change: on Free, history deleted 30 days on, only a start keeps one (as 0133's Free)
  if cardinality(stopped) > 0 then
    -- removals due today (Remove login) go now, so the new date does not put them off
    if cardinality(going) > 0 then
      foreach p in array (select array_agg(x order by x) from unnest(going) x) loop
        perform private.billing_drop_plant(p_user, p);
      end loop;
      update private.billing
         set plants_to_remove = array(select x from unnest(plants_to_remove) x where x <> all (going)),
             free_removals = array(select x from unnest(free_removals) x where x <> all (going))
       where user_id = p_user;
    end if;
    if v_plan = 'free' then
      update private.billing
         set plants_to_remove = array(select distinct x from unnest(plants_to_remove || stopped) x order by x),
             free_removals = array(select distinct x from unnest(free_removals || stopped) x order by x),
             remove_on = b.next_billing_date + 30, updated_at = now()
       where user_id = p_user;
    else
      -- a smaller paid plan was the user's choice: its stopped plants go today (SOLAR-492)
      foreach p in array stopped loop
        perform private.billing_drop_plant(p_user, p);
      end loop;
    end if;
  end if;
  return jsonb_build_object('charge', due, 'plan', v_plan, 'removePlants', to_jsonb(going), 'stopped', to_jsonb(stopped));
end $$;

-- 0186's api_link_status: a drop on a paid change goes on the day it takes effect.
create or replace function public.api_link_status()
 returns table(account_id uuid, sunsynk_username text, status text, linked_at timestamptz, last_ok_at timestamptz, plants jsonb, kind text)
 language sql
 security definer
 set search_path to 'public', 'private', 'pg_temp'
as $function$
  with b as (select bl.*, private.billing_drops(bl) drops from private.billing bl where bl.user_id = auth.uid())
  select a.id, a.sunsynk_username, a.status,
         -- the share login: when this user first claimed through it
         case when a.kind = 'share' then (select min(x.linked_at) from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid())
              else a.linked_at end,
         a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                                                        'paused', pu.paused, 'linked_at', pu.linked_at,
                                                        'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                                                        'remove_on', case when pu.plant_id = any (b.plants_to_remove) then b.remove_on
                                                                          when pu.plant_id = any (b.drops) then private.billing_end_day(b.prepaid_on, b.next_billing_date, b.billing_day)
                                                                            + case when coalesce(b.next_plan, b.plan) = 'free' then 30 else 0 end end,
                                                        'drop', coalesce(pu.plant_id = any (b.drops), false),
                                                        'free_removal', pu.plant_id = any (b.plants_to_remove) and pu.plant_id = any (b.free_removals),
                                                        -- the owner removed the share in SunSynk (0172)
                                                        'share_gone', pu.share_gone_at is not null)
                                    order by pu.linked_at, pu.plant_id)
                     from public.plant_users pu
                     left join b on b.user_id = pu.user_id
                    where pu.account_id = a.id and pu.user_id = auth.uid()),
                  '[]'::jsonb),
         a.kind
    from private.sunsynk_accounts a
   where a.user_id = auth.uid()
      or (a.kind = 'share' and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid()))
   order by 4 desc
$function$;

-- 0186's api_billing_change: the booking email's date, the same way.
create or replace function public.api_billing_change(p_plan text, p_period text default null, p_keep bigint[] default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing; was_booked boolean; was_cancel boolean; drops bigint[];
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  -- for update: a double tap undoes once and emails once; a second cancel is not emailed again
  select next_plan is not null or (next_period is not null and prepaid_on is null), next_plan is not distinct from 'free'
    into was_booked, was_cancel
    from private.billing where user_id = auth.uid() for update;
  perform public.billing_book_change(auth.uid(), p_plan, p_period, p_keep);
  select * into b from private.billing where user_id = auth.uid();
  drops := private.billing_drops(b);
  if was_cancel and b.next_plan = 'free' then
    null;
  elsif b.next_plan is not null or (b.next_period is not null and b.prepaid_on is null) then
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (auth.uid(), 'bill_change', 'bill_change:' || gen_random_uuid(),
            jsonb_build_object('from', b.plan, 'to', coalesce(b.next_plan, b.plan),
              'fromPeriod', b.period, 'toPeriod', coalesce(b.next_period, b.period),
              -- a cancel in a paid year ends when that year does (SOLAR-457)
              'on', case when b.prepaid_on is not null then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                         else b.next_billing_date end,
              'nextAmount', case when coalesce(b.next_plan, b.plan) <> 'free' then public.billing_amount_due(auth.uid()) end,
              'deleteOn', case when cardinality(drops) > 0 then private.billing_end_day(b.prepaid_on, b.next_billing_date, b.billing_day)
                                                             + case when coalesce(b.next_plan, b.plan) = 'free' then 30 else 0 end end,
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
