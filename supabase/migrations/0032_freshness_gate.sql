-- ============================================================================
-- 0032 — freshness gate: skip an inverter whose datalogger has not uploaded.
--
-- The slave inverter uploads every 5 minutes (288 samples/day) while the poller
-- asked SunSynk for all five realtime endpoints every minute — four of every five
-- polls returned the same sample. `device_time` (0031) makes a repeat visible:
-- pvIV[0].time on /realtime/input only advances on an upload.
--
-- The poller now fetches `input` first (needed every minute anyway for PV and the
-- strings) and, when its time equals the inverter's last stored device_time, skips
-- battery / grid / load / output and re-stores the previous row's values under the
-- new ts, marked carried = true. Guard rails live in the poller: never on a refresh
-- minute, never while the last row showed an outage (relay open / mains < 100 V),
-- never after 5 carried rows in a row, never when the last device_time is unknown.
--
-- Two things change here:
--   1. readings.carried — true when the battery/grid/load/output columns were
--      copied from the previous row rather than fetched. The integrity audit and
--      any derivation (step 4's load balance) can exclude these rows.
--   2. inverters_cached() — already called every non-refresh minute — also returns
--      the inverter's last stored reading (as jsonb, so no column list to maintain)
--      and its current run of carried rows. That is everything the gate needs, with
--      no extra round trip. poll_commit is unchanged: the carried row arrives fully
--      populated and lands like any other.
-- ============================================================================

alter table public.readings add column if not exists carried boolean not null default false;

comment on column public.readings.carried is
  'true when battery/grid/load/output columns were copied from the previous row because the datalogger had not uploaded (device_time unchanged). PV, strings and device_time are always fresh.';

drop function if exists public.inverters_cached(uuid);

create or replace function public.inverters_cached(p_account uuid)
returns table (
  sn text, plant_id bigint, alias text, model text, soft_ver text, hmi_ver text,
  gsn text, comm_type text, plant_name text, ord integer, status integer,
  last_reading jsonb, carried_run integer)
language sql
security definer
set search_path = private, pg_temp
as $$
  select i.sn, i.plant_id, m.alias, m.model, m.soft_ver, m.hmi_ver,
         m.gsn, m.comm_type, m.plant_name, m.ord, m.status,
         lr.row as last_reading,
         coalesce(cr.n, 0)::integer as carried_run
    from private.inverters i
    left join private.meta m on m.sn = i.sn
    -- the last stored row, whole, so the poller can carry it forward
    left join lateral (
      select to_jsonb(r) as row
        from public.readings r
       where r.sn = i.sn
       order by r.ts desc
       limit 1) lr on true
    -- how many carried rows sit on top of the last fetched one
    left join lateral (
      select count(*) as n
        from public.readings r
       where r.sn = i.sn
         and r.ts > coalesce((select max(r2.ts) from public.readings r2
                               where r2.sn = i.sn and not r2.carried), 0)) cr on true
   where i.account_id = p_account
   order by coalesce(m.ord, 9999), i.sn
$$;

revoke all on function public.inverters_cached(uuid) from public, anon, authenticated;
grant execute on function public.inverters_cached(uuid) to service_role;

comment on function public.inverters_cached is
  'The account''s inverters from the mirror, each with its last stored reading and current run of carried rows. service_role only.';
