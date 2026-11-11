-- ============================================================================
-- 0186 — the plants a booked change keeps, set as a whole pick (SOLAR-486).
--
-- Billing's "Keep on Home" card ticks the plants that stay once a smaller plan or a
-- cancel starts. 0139's api_billing_keep moves one plant to the front of the pick, so
-- the plant that drops out is the last one, not the one the user unticked. This sets
-- the whole pick: next_keep = p_keep, in the order given.
--
-- Only while a change that stops plants is booked (private.billing_drops not empty, or
-- a pick already in place), and only with exactly as many plants as the new plan keeps,
-- each collecting and not up for removal. Sends no email, as api_billing_keep sends none.
-- ============================================================================

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
  room := private.billing_next_room(b);
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
