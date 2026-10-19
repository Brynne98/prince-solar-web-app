-- ============================================================================
-- 0087 — my_plant() trusts p_plant only from the server; leftover grants go
-- (SOLAR-135, audit 2026-10-19 findings 3 and 7).
--
-- 1. my_plant() returned any p_plant when auth.uid() was null. Over the API that
--    is anon too, so a signed-out caller of any api_* function granted to anon
--    could name any plant. Now only service_role (the Edge Functions: poll,
--    recover, alerts-due) or a direct database session with no API request at
--    all (cron, SQL editor) may name a plant. Everyone else goes through
--    plant_users as before.
--    api_health stays granted to anon (0026) for .github/workflows/health.yml.
--    With the fix anon gets only the all-plants answer; any p_plant raises 42501.
--
-- 2. Production has table grants that no policy uses (RLS blocks them today):
--    anon on inverter_history, authenticated writes on agg_minute, app_config,
--    inverter_history, plant_energy, plant_users, readings and strings, and both
--    roles on every readings_d* / strings_d* partition. The partitions get them
--    from the project's default privileges each night when ensure_day_partition
--    makes one, so it now revokes them too. Access goes through the parent
--    table, which keeps its SELECT grant and policies.
--    plant_config and profiles keep their writes (policies plant_config_write,
--    profiles_own).
-- ============================================================================

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
    select min(plant_id) into v from public.plant_users where user_id = auth.uid();
    if v is null then
      raise exception 'no plant linked to this user' using errcode = 'P0002';
    end if;
    return v;
  end if;
  if exists (select 1 from public.plant_users where user_id = auth.uid() and plant_id = p_plant) then
    return p_plant;
  end if;
  raise exception 'plant % is not linked to this user', p_plant using errcode = '42501';
end $$;
revoke all on function public.my_plant(bigint) from public, anon;
grant execute on function public.my_plant(bigint) to authenticated, service_role;

-- ── leftover grants ─────────────────────────────────────────────────────────
revoke all on public.inverter_history from anon;
revoke insert, update, delete, truncate on
  public.agg_minute, public.app_config, public.inverter_history, public.plant_energy,
  public.plant_users, public.readings, public.strings
  from authenticated;

do $$
declare c regclass;
begin
  for c in select i.inhrelid::regclass from pg_inherits i
            where i.inhparent in ('public.readings'::regclass, 'public.strings'::regclass) loop
    execute format('revoke all on %s from anon, authenticated', c);
  end loop;
end $$;

-- ── new day partitions start without them ───────────────────────────────────
create or replace function private.ensure_day_partition(p_parent text, p_day date)
returns boolean
language plpgsql
set search_path = pg_temp
as $$
declare
  lo bigint := extract(epoch from p_day::timestamp at time zone 'UTC')::bigint;
  child text := format('%s_d%s', p_parent, to_char(p_day, 'YYYYMMDD'));
begin
  -- already covered, by a day partition or a monthly one not yet split
  if exists (
    select 1 from pg_inherits i join pg_class c on c.oid = i.inhrelid
     where i.inhparent = ('public.' || p_parent)::regclass
       and private.partbound_epoch(pg_get_expr(c.relpartbound, c.oid), 'FROM') <= lo
       and private.partbound_epoch(pg_get_expr(c.relpartbound, c.oid), 'TO')   >  lo) then
    return false;
  end if;
  execute format('create table public.%I partition of public.%I for values from (%s) to (%s)',
    child, p_parent, lo, lo + 86400);
  execute format('alter table public.%I enable row level security', child);
  execute format('revoke all on public.%I from anon, authenticated', child);
  return true;
end $$;
revoke all on function private.ensure_day_partition(text, date) from public, anon, authenticated;
