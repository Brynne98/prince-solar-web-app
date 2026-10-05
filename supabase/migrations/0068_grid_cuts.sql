-- ============================================================================
-- 0068 — a permanent list of power cuts (SOLAR-65).
--
-- After 60 days readings become 5-minute rows (SOLAR-60). Those show that a cut
-- touched a bucket but not when it started or ended, and two short cuts merge.
-- This table keeps each cut, start and end, forever: a few rows per home a year.
--
-- THE RULE is q_grid_present's (0055): at each minute the rows carrying the
-- newest device_time vote, and the grid is on if any of them reads over 100 V.
-- Two differences, both about evidence rather than physics:
--   * a voltage of exactly 0 is no reading. A dead grid reads 5-15 V of sensor
--     float, never 0 (OUTAGE_2026-09-18.md); 0 is extract.ts's empty field, and
--     the 2026-09-10 API blackout wrote whole minutes of zeros.
--   * a minute with no voltage at all is unknown. Unknown minutes never start or
--     end a cut; a cut ends at the first minute the grid is seen on again.
-- Whole-plant only: per-phase cuts wait for the L1-blind phase fix (FEATURES.md).
--
-- A cut longer than a day is marked switched_off, the same 24 h line
-- plant_features_detect uses for off-grid: Tshigabe (495944) switches its grid
-- off for days on purpose, and that is not load-shedding.
--
-- private.grid_cuts_update(plant) walks the minutes after the plant's watermark
-- (private.grid_cuts_progress) and extends or opens cuts. A daily job runs it for
-- every linked plant; the end of this migration runs it once over everything
-- still held, which is where history starts (dated voltage from August 2026).
-- ============================================================================

create table if not exists public.grid_cuts (
  plant_id      bigint      not null,
  started_at    timestamptz not null,          -- first minute seen off
  ended_at      timestamptz,                   -- first minute seen on again; null while still off
  last_off_at   timestamptz not null,          -- newest minute seen off
  minutes_off   integer     not null,          -- minutes seen off; the rest of the span had no reading
  switched_off  boolean     not null default false,  -- off for more than a day
  primary key (plant_id, started_at)
);
comment on table public.grid_cuts is
  'Power cuts per plant, start and end, kept forever. Written by private.grid_cuts_update (SOLAR-65).';

create table if not exists private.grid_cuts_progress (
  plant_id   bigint primary key,
  through_ts bigint not null                   -- every minute before this has been walked
);

alter table public.grid_cuts enable row level security;
drop policy if exists grid_cuts_read on public.grid_cuts;
create policy grid_cuts_read on public.grid_cuts for select to authenticated
  using (plant_id in (select public.my_plant_ids()));

drop trigger if exists plant_row_guard on public.grid_cuts;
create trigger plant_row_guard before insert on public.grid_cuts
  for each row execute function private.plant_row_guard();

-- ── minute states ───────────────────────────────────────────────────────────
-- One row per minute that has a voltage: true = grid on, false = off.
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
       and r.grid_volt_v <> 0
  ),
  newest as (
    select v.ts, max(v.device_time) as dt from voters v group by v.ts
  )
  select v.ts, bool_or(v.grid_volt_v > 100)
    from voters v join newest n on n.ts = v.ts
   where v.device_time is not distinct from n.dt
   group by v.ts
$$;

-- ── walk ────────────────────────────────────────────────────────────────────
create or replace function private.grid_cuts_update(p_plant bigint, p_to bigint default null)
returns integer
language plpgsql
set search_path = public, private, pg_temp
as $$
declare
  hi   bigint := coalesce(p_to, (extract(epoch from now())::bigint / 60) * 60 - 120);
  lo   bigint;
  open public.grid_cuts;
  m    record;
  n    integer := 0;
begin
  select through_ts into lo from private.grid_cuts_progress where plant_id = p_plant;
  if lo is null then
    select min(r.ts) into lo from public.readings r where r.plant_id = p_plant;
  end if;
  if lo is null or lo >= hi then return 0; end if;

  select * into open from public.grid_cuts
   where plant_id = p_plant and ended_at is null
   order by started_at desc limit 1;

  for m in select * from private.grid_minutes(p_plant, lo, hi) order by ts loop
    n := n + 1;
    if not m.present then
      if open.plant_id is null then
        open := (p_plant, to_timestamp(m.ts), null, to_timestamp(m.ts), 0, false)::public.grid_cuts;
      end if;
      open.last_off_at := to_timestamp(m.ts);
      open.minutes_off := open.minutes_off + 1;
    elsif open.plant_id is not null then
      open.ended_at := to_timestamp(m.ts);
      open.switched_off := open.ended_at - open.started_at > interval '1 day';
      insert into public.grid_cuts values (open.*)
      on conflict (plant_id, started_at) do update
        set ended_at = excluded.ended_at, last_off_at = excluded.last_off_at,
            minutes_off = excluded.minutes_off, switched_off = excluded.switched_off;
      open := null;
    end if;
  end loop;

  if open.plant_id is not null then
    open.switched_off := open.last_off_at - open.started_at > interval '1 day';
    insert into public.grid_cuts values (open.*)
    on conflict (plant_id, started_at) do update
      set last_off_at = excluded.last_off_at, minutes_off = excluded.minutes_off,
          switched_off = excluded.switched_off;
  end if;

  insert into private.grid_cuts_progress (plant_id, through_ts) values (p_plant, hi)
  on conflict (plant_id) do update set through_ts = excluded.through_ts;
  return n;
end $$;

create or replace function private.grid_cuts_update_all()
returns jsonb
language plpgsql
set search_path = public, private, pg_temp
as $$
declare p bigint; out jsonb := '{}'::jsonb;
begin
  for p in select distinct plant_id from public.plant_users loop
    out := out || jsonb_build_object(p::text, private.grid_cuts_update(p));
  end loop;
  return out;
end $$;

revoke all on function private.grid_minutes(bigint, bigint, bigint) from public, anon, authenticated;
revoke all on function private.grid_cuts_update(bigint, bigint) from public, anon, authenticated;
revoke all on function private.grid_cuts_update_all() from public, anon, authenticated;

-- ── purge: 0056's body plus the two new tables ──────────────────────────────
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
  delete from public.grid_cuts        where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('grid_cuts', n);
  delete from public.plant_config     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from private.gaps            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('gaps', n);
  delete from private.meta            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters       where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  delete from private.grid_cuts_progress where plant_id = p_plant;
  delete from private.plant_purge     where plant_id = p_plant;
  return out;
end $$;

-- ── schedule: daily 04:10 UTC, clear of the 04:30 partition drop ────────────
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping grid-cuts job (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'grid-cuts') then
    perform cron.unschedule('grid-cuts');
  end if;
  perform cron.schedule('grid-cuts', '10 4 * * *', 'select private.grid_cuts_update_all()');
end $$;

-- Walk everything still held, before the July-August partitions are dropped.
do $$
begin
  raise notice 'grid_cuts backfill: %', private.grid_cuts_update_all();
end $$;
