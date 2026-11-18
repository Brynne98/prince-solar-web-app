-- ============================================================================
-- 0223 — the plants an owner picks are final while a plan runs (SOLAR-583, decided
--        by Brynne 2026-11-18).
--
-- Before (0197): one change per account per 90 days (api_plant_change, private.plant_change).
--
-- Now:
--   - No change by the owner. To watch another plant: a bigger plan.
--   - An inverter replaced or dead, or Family with more than 5 plants: the owner emails
--     us and we swap one plant by hand with private.plant_swap (psql, service role).
--   - A plan that ends resets nothing here: with no plan the owner may tick locked plants
--     into open places (api_plant_pick, room 5) and chooses which stay at the next payment
--     (api_billing_start_keep). An account delete takes its ticks with it (0197).
--
-- Support swap:
--   select private.plant_swap('<user uuid>', <plant out>, <plant in>);
-- The plant out loses its tick and, when nobody else runs it, its history at once (as 0125's
-- stop). The plant in takes the place and fetches its last 60 days (plant_run).
-- ============================================================================

drop function if exists public.api_plant_change(bigint, bigint);
drop table if exists private.plant_change;

create or replace function private.plant_swap(p_user uuid, p_out bigint, p_in bigint)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare plant_in public.plant_users;
begin
  perform private.billing_lock(p_user);
  if p_out is null or p_in is null or p_out = p_in
     or not exists (select 1 from private.plant_picks where user_id = p_user and plant_id = p_out) then
    raise exception 'plant % is not picked', p_out using errcode = '22023';
  end if;
  select * into plant_in from public.plant_users where user_id = p_user and plant_id = p_in and share_gone_at is null;
  if not found then raise exception 'plant % is not linked to this user', p_in using errcode = '22023'; end if;
  if not plant_in.paused then raise exception 'plant % already runs', p_in using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(least(p_out, p_in));
  perform pg_advisory_xact_lock(greatest(p_out, p_in));

  update public.plant_users set paused = true where user_id = p_user and plant_id = p_out and not paused;
  -- A plant someone else still collects keeps its readings; the wipe checks again when it runs (0125).
  if found and not exists (select 1 from public.plant_users where plant_id = p_out and not paused) then
    insert into private.plant_wipe (plant_id) values (p_out) on conflict (plant_id) do nothing;
  end if;
  delete from private.plant_picks where user_id = p_user and plant_id = p_out;
  insert into private.plant_picks (user_id, plant_id, plant_name) values (p_user, p_in, plant_in.plant_name)
  on conflict do nothing;
  perform private.plant_run(p_user, p_in);
end $$;
revoke all on function private.plant_swap(uuid, bigint, bigint) from public, anon, authenticated;

-- 0197's api_plant_picks, with no change_on.
create or replace function public.api_plant_picks()
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object(
    'plan', coalesce((select b.plan from private.billing b where b.user_id = auth.uid()), 'free'),
    -- free of charge: no limit, so the screens show no number
    'comped', coalesce((select b.comped from private.billing b where b.user_id = auth.uid()), false),
    'room', (select public.billing_room(b.plan, b.extra_plants)
               from (select auth.uid() u) me left join private.billing b on b.user_id = me.u),
    'picks', coalesce((select jsonb_agg(jsonb_build_object(
                         'plant_id', k.plant_id,
                         'plant_name', coalesce(pu.plant_name, k.plant_name, 'Plant ' || k.plant_id),
                         'held', k.held,
                         'linked', pu.plant_id is not null,
                         'running', coalesce(not pu.paused, false))
                       order by k.picked_at, k.plant_id)
                from private.plant_picks k
                left join public.plant_users pu on pu.user_id = k.user_id and pu.plant_id = k.plant_id
               where k.user_id = auth.uid()), '[]'::jsonb))
$$;
revoke all on function public.api_plant_picks() from public, anon;
grant execute on function public.api_plant_picks() to authenticated, service_role;
