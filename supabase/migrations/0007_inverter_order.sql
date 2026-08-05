-- ============================================================================
-- Preserve SunSynk's inverter ordering.
--
-- Express renders inverters in the order the /inverters list endpoint returns them
-- (master first here). Sorting by serial instead silently swapped the two cards on
-- the Overview tab. Capture the list position at poll time and order by it.
--
-- Historical rows migrated from SQLite have no ordinal; they get one on the next
-- poll, and until then fall back to serial order.
-- ============================================================================

alter table private.meta add column if not exists ord integer;

create or replace function public.meta_upsert(p_rows jsonb)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  insert into private.meta (
    sn, updated_ts, alias, model, soft_ver, hmi_ver, gsn, comm_type,
    capacity_ah, number_of_batteries, plant_id, plant_name, ord)
  select
    r->>'sn',
    (r->>'updated_ts')::bigint,
    r->>'alias', r->>'model', r->>'soft_ver', r->>'hmi_ver', r->>'gsn', r->>'comm_type',
    nullif(r->>'capacity_ah', '')::double precision,
    nullif(r->>'number_of_batteries', '')::integer,
    nullif(r->>'plant_id', '')::bigint,
    r->>'plant_name',
    nullif(r->>'ord', '')::integer
  from jsonb_array_elements(p_rows) r
  on conflict (sn) do update set
    updated_ts = excluded.updated_ts, alias = excluded.alias, model = excluded.model,
    soft_ver = excluded.soft_ver, hmi_ver = excluded.hmi_ver, gsn = excluded.gsn,
    comm_type = excluded.comm_type, capacity_ah = excluded.capacity_ah,
    number_of_batteries = excluded.number_of_batteries,
    plant_id = excluded.plant_id, plant_name = excluded.plant_name,
    ord = coalesce(excluded.ord, private.meta.ord)
$$;

revoke all on function public.meta_upsert(jsonb) from public, anon, authenticated;
grant execute on function public.meta_upsert(jsonb) to service_role;
