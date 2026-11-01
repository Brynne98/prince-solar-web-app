-- ============================================================================
-- 0139 — Remove login removes it now, on every plan (SOLAR-299, Brynne 2026-11-01).
--
-- Logins and billing are separate. Billing pays for room for plants; logins are the
-- user's to manage. On a paid plan Remove login booked its plants for deletion on the
-- billing date and Keep took one plant back, so a removed login could stay with part of
-- its plants. Now Remove login deletes the login and every plant on it at once, as on
-- Free (api_link_disconnect, 0096); the app says so before it asks. The room paid for
-- stays until the billing date.
--
-- Keep is left for the plants a booked downgrade stops on the billing date (0136): it
-- swaps the plant into the pick. Plants the move to Free booked come back only by a
-- start (0133). A removal booked before this (billing_book_removal, no longer called by
-- the app; none were pending on 2026-11-01) comes back whole: every plant of its login.
-- ============================================================================

create or replace function public.api_link_remove(p_account uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and user_id = auth.uid()) then
    raise exception 'not your account' using errcode = '42501';
  end if;
  perform public.api_link_disconnect(p_account);
  -- plants gone: off the delete lists too
  update private.billing
     set plants_to_remove = array(select x from unnest(plants_to_remove) x
                                   where exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = x)),
         free_removals = array(select x from unnest(free_removals) x
                                where exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = x)),
         updated_at = now()
   where user_id = auth.uid() and cardinality(plants_to_remove) > 0;
  update private.billing set remove_on = null where user_id = auth.uid() and cardinality(plants_to_remove) = 0 and remove_on is not null;
  return jsonb_build_object('result', 'removed');
end $$;

-- 0136's keep: swaps a plant a booked downgrade stops into the pick.
create or replace function public.api_billing_keep(p_plant bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  picks bigint[];
  acc uuid;
  kept bigint[];
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(auth.uid());
  select * into b from private.billing where user_id = auth.uid() for update;
  if p_plant = any (private.billing_drops(b)) then
    select coalesce(array_agg(plant_id order by array_position(b.next_keep, plant_id) nulls last, linked_at, plant_id), '{}')
      into picks from public.plant_users
     where user_id = auth.uid() and not paused and plant_id <> all (coalesce(b.plants_to_remove, '{}'))
       and plant_id <> all (private.billing_drops(b));
    update private.billing
       set next_keep = (array[p_plant] || picks)[1:private.billing_next_room(b)], updated_at = now()
     where user_id = auth.uid();
    return public.api_billing_status();
  end if;
  -- booked by a move to Free: only a start keeps it (0131, 0133)
  if coalesce(b.plan, 'free') = 'free'
     or (p_plant = any (coalesce(b.free_removals, '{}')) and p_plant = any (b.plants_to_remove)) then
    raise exception 'start it instead' using errcode = '22023';
  end if;
  -- a removal booked before 0139 (billing_book_removal): its login comes back whole
  select account_id into acc from public.plant_users where user_id = auth.uid() and plant_id = p_plant;
  select coalesce(array_agg(plant_id), '{}') into kept from public.plant_users
   where user_id = auth.uid() and plant_id = any (b.plants_to_remove) and plant_id <> all (coalesce(b.free_removals, '{}'))
     and (plant_id = p_plant or (acc is not null and account_id = acc));
  update private.billing
     set plants_to_remove = array(select x from unnest(plants_to_remove) x where x <> all (kept)), updated_at = now()
   where user_id = auth.uid() and cardinality(kept) > 0;
  update private.billing set remove_on = null where user_id = auth.uid() and cardinality(plants_to_remove) = 0 and remove_on is not null;
  return public.api_billing_status();
end $$;
