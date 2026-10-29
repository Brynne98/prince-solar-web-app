-- ============================================================================
-- 0123 — the battery reserve step is confirmed on the plant, not per account (SOLAR-247).
--
-- First steps counts the reserve as done once it is not 20% or someone pressed Save
-- on the step. That press lived in the account's prefs (firstSteps[plant].reserve),
-- so a second account on the plant saw 3/4 although the plant was set up. It is now
-- plant_config.battery_reserve_confirmed, like the other three steps' settings.
-- The prefs mark stays where it is; nothing reads it after this.
-- ============================================================================

alter table public.plant_config add column if not exists battery_reserve_confirmed boolean not null default false;

-- Plants someone already confirmed, or whose reserve was changed
update public.plant_config c
   set battery_reserve_confirmed = true
 where not c.battery_reserve_confirmed
   and (coalesce(c.battery_reserve_pct, 20) <> 20
        or exists (select 1 from public.plant_users pu join public.profiles p on p.user_id = pu.user_id
                    where pu.plant_id = c.plant_id
                      and (coalesce((p.prefs->'firstSteps'->(c.plant_id::text)->>'reserve')::boolean, false)
                           or coalesce((p.prefs->'firstSteps'->(c.plant_id::text)->>'done')::boolean, false))));

-- 0122's day-2 check, reading the plant's flag in place of the account's prefs mark
create or replace function private.setup_steps_left(p_user uuid, p_plant bigint)
returns text[]
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select case when coalesce((m->>'done')::boolean, false) then '{}'::text[] else array_remove(array[
           case when not coalesce(c.tariff_import > 0, false) then 'rate' end,
           case when c.has_battery is distinct from false and not coalesce(c.battery_kwh > 0, false) then 'size' end,
           case when c.has_battery is distinct from false and not coalesce(c.battery_reserve_confirmed, false)
                 and coalesce(c.battery_reserve_pct, 20) = 20 then 'reserve' end,
           case when not coalesce(c.system_kwp > 0, false) then 'panels' end], null) end
    from (select 1) one
    left join public.plant_config c on c.plant_id = p_plant
    left join lateral (
      select pr.prefs->'firstSteps'->(p_plant::text) as m
        from public.profiles pr where pr.user_id = p_user) p on true
$$;
revoke all on function private.setup_steps_left(uuid, bigint) from public, anon, authenticated;
