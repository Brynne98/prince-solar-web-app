-- ============================================================================
-- 0069 — power cuts become "grid off" periods (SOLAR-65 follow-up to 0068).
--
-- 1. A DATED 0 V IS A REAL READING. 0068 treated every 0 V as no reading, after
--    538820's dead grid read 5-15 V and the 2026-09-10 API blackout wrote
--    minutes of zeros. Tshigabe (495944) reads exactly 0 V with its grid
--    switched off: 93,589 dated rows, none between 0 and 100, so none of its
--    off stretches were logged. The junk zeros carry no device_time, so a 0 V
--    reading now counts when it is dated.
--
-- 2. NO CAUSE IS GUESSED. Tshigabe switches its grid off because it rarely
--    needs it; the readings look exactly like a utility outage. 0068's
--    switched_off flag (off for more than a day) was a guess that also called a
--    10-hour switch-off a cut. The table now records only what the meter saw,
--    periods with no grid power, and is renamed to say so: public.grid_off. A
--    later load-shedding feature decides the cause (ask the owner, or check the
--    published schedule). Decided by Brynne, 2026-10-05.
--
-- The list is rebuilt from what is still held.
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'grid-cuts') then
    perform cron.unschedule('grid-cuts');
  end if;
end $$;

drop function if exists private.grid_cuts_update_all();
drop function if exists private.grid_cuts_update(bigint, bigint);

alter table public.grid_cuts rename to grid_off;
alter table public.grid_off drop column switched_off;
alter table public.grid_off rename constraint grid_cuts_pkey to grid_off_pkey;
alter policy grid_cuts_read on public.grid_off rename to grid_off_read;
comment on table public.grid_off is
  'Periods with no grid power per plant, start and end, kept forever. The cause '
  '(utility outage or switched off by the owner) is not recorded. Written by '
  'private.grid_off_update (SOLAR-65).';
alter table private.grid_cuts_progress rename to grid_off_progress;

-- ── minute states: a dated 0 V counts ───────────────────────────────────────
create or replace function private.grid_minutes(p_plant bigint, p_from bigint, p_to bigint)
returns table (ts bigint, present boolean)
language sql
stable
set search_path = public, pg_temp
as $$
  with voters as (
    select r.ts, r.grid_volt_v, r.device_time
      from public.readings r
     where r.plant_id = p_plant
       and r.ts >= p_from and r.ts < p_to
       and r.grid_volt_v is not null
       and (r.grid_volt_v <> 0 or r.device_time is not null)
  ),
  newest as (
    select v.ts, max(v.device_time) as dt from voters v group by v.ts
  )
  select v.ts, bool_or(v.grid_volt_v > 100)
    from voters v join newest n on n.ts = v.ts
   where v.device_time is not distinct from n.dt
   group by v.ts
$$;

-- ── walk: 0068's, without the flag ──────────────────────────────────────────
create or replace function private.grid_off_update(p_plant bigint, p_to bigint default null)
returns integer
language plpgsql
set search_path = public, private, pg_temp
as $$
declare
  hi   bigint := coalesce(p_to, (extract(epoch from now())::bigint / 60) * 60 - 120);
  lo   bigint;
  open public.grid_off;
  m    record;
  n    integer := 0;
begin
  select through_ts into lo from private.grid_off_progress where plant_id = p_plant;
  if lo is null then
    select min(r.ts) into lo from public.readings r where r.plant_id = p_plant;
  end if;
  if lo is null or lo >= hi then return 0; end if;

  select * into open from public.grid_off
   where plant_id = p_plant and ended_at is null
   order by started_at desc limit 1;

  for m in select * from private.grid_minutes(p_plant, lo, hi) order by ts loop
    n := n + 1;
    if not m.present then
      if open.plant_id is null then
        open := (p_plant, to_timestamp(m.ts), null, to_timestamp(m.ts), 0)::public.grid_off;
      end if;
      open.last_off_at := to_timestamp(m.ts);
      open.minutes_off := open.minutes_off + 1;
    elsif open.plant_id is not null then
      open.ended_at := to_timestamp(m.ts);
      insert into public.grid_off values (open.*)
      on conflict (plant_id, started_at) do update
        set ended_at = excluded.ended_at, last_off_at = excluded.last_off_at,
            minutes_off = excluded.minutes_off;
      open := null;
    end if;
  end loop;

  if open.plant_id is not null then
    insert into public.grid_off values (open.*)
    on conflict (plant_id, started_at) do update
      set last_off_at = excluded.last_off_at, minutes_off = excluded.minutes_off;
  end if;

  insert into private.grid_off_progress (plant_id, through_ts) values (p_plant, hi)
  on conflict (plant_id) do update set through_ts = excluded.through_ts;
  return n;
end $$;

create or replace function private.grid_off_update_all()
returns jsonb
language plpgsql
set search_path = public, private, pg_temp
as $$
declare p bigint; out jsonb := '{}'::jsonb;
begin
  for p in select distinct plant_id from public.plant_users loop
    out := out || jsonb_build_object(p::text, private.grid_off_update(p));
  end loop;
  return out;
end $$;

revoke all on function private.grid_minutes(bigint, bigint, bigint) from public, anon, authenticated;
revoke all on function private.grid_off_update(bigint, bigint) from public, anon, authenticated;
revoke all on function private.grid_off_update_all() from public, anon, authenticated;

-- ── purge: 0068's body with the renamed tables ──────────────────────────────
create or replace function private.purge_plant(p_plant bigint, p_wait boolean default true)
returns jsonb
language plpgsql
set search_path = public, private, pg_temp
as $$
declare
  out jsonb := '{}'::jsonb;
  n bigint;
begin
  if p_wait then
    perform pg_advisory_xact_lock(p_plant);
  elsif not pg_try_advisory_xact_lock(p_plant) then
    return null;
  end if;
  if not exists (select 1 from private.plant_purge where plant_id = p_plant) then
    return null;
  end if;
  if exists (select 1 from public.plant_users where plant_id = p_plant) then
    delete from private.plant_purge where plant_id = p_plant;
    return jsonb_build_object('skipped', 'linked again');
  end if;

  delete from public.readings         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings', n);
  delete from public.strings          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings', n);
  delete from public.agg_minute       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_minute', n);
  delete from public.plant_energy     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_energy', n);
  delete from public.inverter_history where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history', n);
  delete from public.grid_off         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('grid_off', n);
  delete from public.plant_config     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from private.gaps            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('gaps', n);
  delete from private.meta            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  delete from private.grid_off_progress where plant_id = p_plant;
  delete from private.plant_purge     where plant_id = p_plant;
  return out;
end $$;

-- ── schedule: same slot, new name ───────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping grid-off job (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'grid-off') then
    perform cron.unschedule('grid-off');
  end if;
  perform cron.schedule('grid-off', '10 4 * * *', 'select private.grid_off_update_all()');
end $$;

-- Rebuild from scratch: the readings behind every row are still held.
delete from public.grid_off;
delete from private.grid_off_progress;
do $$
begin
  raise notice 'grid_off rebuild: %', private.grid_off_update_all();
end $$;
