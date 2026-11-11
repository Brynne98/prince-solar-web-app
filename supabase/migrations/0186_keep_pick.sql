-- ============================================================================
-- 0186 — the plants a booked change keeps, set as a whole pick (SOLAR-486).
--
-- Billing's "Keep on Home" card ticks the plants that stay once a smaller plan or a
-- cancel starts. 0139's api_billing_keep moves one plant to the front of the pick, so
-- the plant that drops out is the last one, not the one the user unticked. This sets
-- the whole pick: next_keep = p_keep, in the order given.
--
-- Only while a change that stops plants is booked, and only with exactly as many plants
-- as the new plan keeps, each collecting and not up for removal. Sends no email, as
-- api_billing_keep sends none.
--
-- A cancel in a paid year (0175, prepaid_on) picks the same way (Brynne 2026-11-11: "why
-- wouldn't it work the same way?"). 0175 left its drops empty so the paid plan's room
-- holds until the year ends; billing_next_room still says so, and starts and links keep
-- that room. Only the pick now counts Free's 1 plant: billing_drops, the plants list and
-- the booking email, with the deletion date 30 days after that year ends, not after the
-- billing date the year starts on.
-- ============================================================================

-- How many plants a booked change keeps, for the pick: billing_next_room, and Free's room
-- for a cancel in a paid year.
create or replace function private.billing_pick_room(b private.billing)
returns int language sql immutable as $$
  select case when b.prepaid_on is not null and b.next_plan = 'free' then public.billing_room('free', 0)
              else private.billing_next_room(b) end
$$;
revoke all on function private.billing_pick_room(private.billing) from public, anon, authenticated;

-- 0136's drops, counted against the pick's room.
create or replace function private.billing_drops(b private.billing)
returns bigint[] language sql stable set search_path = public, private, pg_temp as $$
  select coalesce(array_agg(plant_id order by plant_id), '{}') from (
    select pu.plant_id from public.plant_users pu
     where pu.user_id = b.user_id and not pu.paused and pu.plant_id <> all (coalesce(b.plants_to_remove, '{}'))
     order by array_position(b.next_keep, pu.plant_id) nulls last, pu.linked_at, pu.plant_id
    offset private.billing_pick_room(b)) x
   where private.billing_pick_room(b) is not null and not coalesce(b.comped, false)
$$;
revoke all on function private.billing_drops(private.billing) from public, anon, authenticated;

-- The day a booked change takes effect: the billing date, or a year on when that year is paid.
create or replace function private.billing_end_day(p_prepaid date, p_next date, p_day smallint)
returns date language sql immutable set search_path = public, private, pg_temp as $$
  select case when p_prepaid is not null then public.billing_step(p_next, 'yearly', p_day, 1) else p_next end
$$;
revoke all on function private.billing_end_day(date, date, smallint) from public, anon, authenticated;

create or replace function public.api_billing_keep_set(p_keep bigint[])
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  room int;
  can bigint[];
  k bigint[];
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(auth.uid());
  select * into b from private.billing where user_id = auth.uid() for update;
  room := private.billing_pick_room(b);
  -- the plants a pick can hold: collecting and not up for removal, as billing_drops counts them
  select coalesce(array_agg(plant_id), '{}') into can from public.plant_users
   where user_id = auth.uid() and not paused and plant_id <> all (coalesce(b.plants_to_remove, '{}'));
  if room is null or coalesce(b.comped, false) or cardinality(can) <= room then
    raise exception 'nothing to pick' using errcode = '22023';
  end if;
  k := private.billing_keep_list(auth.uid(), p_keep);
  if cardinality(k) <> room or not (k <@ can) or cardinality(k) <> cardinality(coalesce(p_keep, '{}')) then
    raise exception 'pick % plants', room using errcode = '22023';
  end if;
  update private.billing set next_keep = k, updated_at = now() where user_id = auth.uid();
  return public.api_billing_status();
end $$;
revoke all on function public.api_billing_keep_set(bigint[]) from public, anon;
grant execute on function public.api_billing_keep_set(bigint[]) to authenticated;

-- 0185's api_link_status: a plant a booked change stops is deleted 30 days after the change
-- takes effect, a year on for a cancel in a paid year.
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
                                                                          when pu.plant_id = any (b.drops) then private.billing_end_day(b.prepaid_on, b.next_billing_date, b.billing_day) + 30 end,
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

-- 0176's api_billing_change: the booking email's deletion date, the same way.
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
              'deleteOn', case when cardinality(drops) > 0 then private.billing_end_day(b.prepaid_on, b.next_billing_date, b.billing_day) + 30 end,
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
