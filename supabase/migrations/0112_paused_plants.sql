-- ============================================================================
-- 0112 — paused plants are listed but not read (SOLAR-208, decided 2026-10-27).
--
-- A plant the plan doesn't cover links as paused (plant_users.paused, 0110). The
-- user sees it in Account and nowhere else:
--   - my_plant / my_plant_ids, which every api_* reader and the RLS policies go
--     through, skip a paused plant. So do api_me's plants (the plant switcher).
--   - api_link_status lists every plant with its state: paused, the removal date
--     when the plant is booked for deletion (private.billing), and its inverter
--     count, so the paywall can price a paused plant.
--   - email_queue drops plant mail (alerts, reports, history) for a user who has
--     that plant paused. One trigger, so every sender is covered.
-- poll skips a plant paused for every account that sees it (plantsToPoll), so no
-- data is saved for it. A plant shared with someone it is active for keeps polling.
-- ============================================================================

create or replace function public.my_plant_ids()
returns setof bigint
language sql
stable
security invoker
set search_path = public, pg_temp
as $$ select plant_id from public.plant_users where user_id = auth.uid() and not paused $$;

create or replace function public.my_plant(p_plant bigint default null)
returns bigint
language plpgsql
stable
security invoker
set search_path = public, pg_temp
as $$
declare v bigint;
begin
  -- The server (service_role, or no API request at all) has already decided
  -- which plant it is working on: trust it. auth.role() is null only off the API.
  if p_plant is not null and coalesce(auth.role(), 'service_role') = 'service_role' then
    return p_plant;
  end if;
  if p_plant is null then
    select min(plant_id) into v from public.plant_users where user_id = auth.uid() and not paused;
    if v is null then
      raise exception 'no plant linked to this user' using errcode = 'P0002';
    end if;
    return v;
  end if;
  if exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = p_plant and not paused) then
    return p_plant;
  end if;
  raise exception 'plant % is not linked to this user', p_plant using errcode = '42501';
end $$;
-- create or replace keeps the grants from 0024 and 0087.

drop function if exists public.api_link_status();
create function public.api_link_status()
returns table (account_id uuid, sunsynk_username text, status text, linked_at timestamptz,
               last_ok_at timestamptz, plants jsonb)
language sql
security definer
set search_path = public, private, pg_temp
as $$
  select a.id, a.sunsynk_username, a.status, a.linked_at, a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                                                        'paused', pu.paused,
                                                        'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                                                        'remove_on', case when pu.plant_id = any (b.plants_to_remove) then b.remove_on end)
                                    order by pu.linked_at, pu.plant_id)
                     from public.plant_users pu
                     left join private.billing b on b.user_id = pu.user_id
                    where pu.account_id = a.id and pu.user_id = auth.uid()),
                  '[]'::jsonb)
    from private.sunsynk_accounts a
   where a.user_id = auth.uid()
   order by a.linked_at desc
$$;
revoke all on function public.api_link_status() from public, anon;
grant execute on function public.api_link_status() to authenticated, service_role;

create or replace function private.email_skip_paused()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.plant_id is not null and exists (select 1 from public.plant_users pu
       where pu.user_id = new.user_id and pu.plant_id = new.plant_id and pu.paused) then
    return null;
  end if;
  return new;
end $$;
revoke all on function private.email_skip_paused() from public, anon, authenticated;
drop trigger if exists email_skip_paused on public.email_queue;
create trigger email_skip_paused before insert on public.email_queue
  for each row execute function private.email_skip_paused();
