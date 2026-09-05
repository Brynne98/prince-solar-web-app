-- ============================================================================
-- 0031 — inverter cache for the poller; device-side sample time on readings.
--
-- 1. `poll` asked SunSynk for the account's inverter list every minute, then wrote
--    the answer into private.inverters + private.meta. Everything it needs from that
--    list is already mirrored there except the online/offline `status`, so add that
--    column and an accessor that rebuilds the list from the mirror. The poller now
--    refreshes from SunSynk every 10 minutes and reads the cache in between.
--
-- 2. readings.device_time: the inverter's own timestamp for the sample, taken from
--    pvIV[0].time on /realtime/input ("2026-09-04 15:43:47", plant-local, text kept
--    verbatim). Nothing recorded this before, so a minute that repeats SunSynk's
--    previous sample was indistinguishable from a genuinely unchanged one. The slave
--    inverter uploads every 5 minutes; this column is the evidence the next change
--    (skip an inverter that has not uploaded) needs. poll_commit needs no change:
--    it populates rows with jsonb_populate_recordset, so the new key just lands.
-- ============================================================================

alter table private.meta add column if not exists status integer;
alter table public.readings add column if not exists device_time text;

comment on column public.readings.device_time is
  'Inverter-side timestamp of the sample (pvIV[0].time on /realtime/input), plant-local, verbatim. Null before 0031.';

-- meta_upsert: 0007's body plus status. Absent status leaves the stored one alone.
create or replace function public.meta_upsert(p_rows jsonb)
returns void
language sql
security definer
set search_path = private, pg_temp
as $$
  insert into private.meta (
    sn, updated_ts, alias, model, soft_ver, hmi_ver, gsn, comm_type,
    capacity_ah, number_of_batteries, plant_id, plant_name, ord, status)
  select
    r->>'sn',
    (r->>'updated_ts')::bigint,
    r->>'alias', r->>'model', r->>'soft_ver', r->>'hmi_ver', r->>'gsn', r->>'comm_type',
    nullif(r->>'capacity_ah', '')::double precision,
    nullif(r->>'number_of_batteries', '')::integer,
    nullif(r->>'plant_id', '')::bigint,
    r->>'plant_name',
    nullif(r->>'ord', '')::integer,
    nullif(r->>'status', '')::integer
  from jsonb_array_elements(p_rows) r
  on conflict (sn) do update set
    updated_ts = excluded.updated_ts, alias = excluded.alias, model = excluded.model,
    soft_ver = excluded.soft_ver, hmi_ver = excluded.hmi_ver, gsn = excluded.gsn,
    comm_type = excluded.comm_type, capacity_ah = excluded.capacity_ah,
    number_of_batteries = excluded.number_of_batteries,
    plant_id = excluded.plant_id, plant_name = excluded.plant_name,
    ord = coalesce(excluded.ord, private.meta.ord),
    status = coalesce(excluded.status, private.meta.status)
$$;

-- The account's inverters as the poller last saw them, in SunSynk's list order.
create or replace function public.inverters_cached(p_account uuid)
returns table (
  sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text,
  gsn text, comm_type text, plant_name text, ord integer, status integer)
language sql
security definer
set search_path = private, pg_temp
as $$
  select i.sn, i.plant_id, m.alias, m.model, m.soft_ver, m.hmi_ver,
         m.gsn, m.comm_type, m.plant_name, m.ord, m.status
    from private.inverters i
    left join private.meta m on m.sn = i.sn
   where i.account_id = p_account
   order by coalesce(m.ord, 9999), i.sn
$$;

revoke all on function public.meta_upsert(jsonb) from public, anon, authenticated;
grant execute on function public.meta_upsert(jsonb) to service_role;
revoke all on function public.inverters_cached(uuid) from public, anon, authenticated;
grant execute on function public.inverters_cached(uuid) to service_role;
