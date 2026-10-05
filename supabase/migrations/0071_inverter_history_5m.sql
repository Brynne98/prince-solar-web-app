-- ============================================================================
-- 0071 — inverter history: device samples for 60 days, then 5-minute rows
-- forever (SOLAR-61).
--
-- inverter_history is the only record of AC terminal voltage, grid frequency
-- and inverter temperature, and q_prune_inverter_history deleted it at 120
-- days. Now every sample older than 61 days is summarised into
-- inverter_history_5m and then deleted. 61, not 60: recover's walk refetches
-- back to today-60, so a thinned day is never written again. Decided by
-- Brynne, 2026-10-05 (SOLAR-43 review, option A).
--
-- A 5-minute row holds exactly what api_inverter_history already draws per
-- bucket (max AC/DC temperature, min/max/last terminal voltage, min/max AC and
-- grid frequency) plus dc_min, for the "DC sensor never moved" check, and n.
-- Buckets are epoch/300; every plant timezone offset is a multiple of 300 s,
-- so they line up with the reader's local-day buckets.
--
-- q_prune_inverter_history keeps its name and signature: recover calls it
-- every 6 hours, so no function deploy is needed. Its default age moves from
-- 120 to 61 days and it summarises before it deletes. api_inverter_history
-- reads a bucket from the raw samples when it has any, from the 5-minute row
-- otherwise, so an old day draws the same chart. The frontend's 60-day date
-- limit (chart.jsx DAY_FLOOR_DAYS) is unchanged here.
-- ============================================================================

create table if not exists public.inverter_history_5m (
  plant_id    bigint   not null,
  sn          text     not null,
  ts          bigint   not null,     -- bucket start, epoch seconds, multiple of 300
  n           smallint not null,
  ac_max      real,
  dc_max      real,
  dc_min      real,
  vac_min     real,
  vac_max     real,
  vac_last    real,
  fac_min     real,
  fac_max     real,
  gfac_min    real,
  gfac_max    real,
  primary key (plant_id, sn, ts)
);
comment on table public.inverter_history_5m is
  'inverter_history older than 61 days, one row per inverter per 5 minutes: the per-bucket values api_inverter_history draws. Written by q_prune_inverter_history (SOLAR-61).';

alter table public.inverter_history_5m enable row level security;
drop policy if exists inverter_history_5m_read on public.inverter_history_5m;
create policy inverter_history_5m_read on public.inverter_history_5m for select to authenticated
  using (plant_id in (select public.my_plant_ids()));

-- ── summarise, then delete ──────────────────────────────────────────────────
create or replace function public.q_prune_inverter_history(p_plant bigint, p_days integer default 61)
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare
  cutoff bigint := ((extract(epoch from now())::bigint - p_days * 86400) / 300) * 300;
  n integer;
begin
  insert into public.inverter_history_5m
    (plant_id, sn, ts, n, ac_max, dc_max, dc_min, vac_min, vac_max, vac_last, fac_min, fac_max, gfac_min, gfac_max)
  select plant_id, sn, (ts / 300) * 300, count(*),
         max(ac_c), max(dc_c), min(dc_c), min(vac_v), max(vac_v),
         (array_agg(vac_v order by ts desc) filter (where vac_v is not null))[1],
         min(fac_hz), max(fac_hz), min(grid_fac_hz), max(grid_fac_hz)
    from public.inverter_history
   where plant_id = p_plant and ts < cutoff
   group by plant_id, sn, (ts / 300) * 300
  on conflict do nothing;

  with del as (
    delete from public.inverter_history
     where plant_id = p_plant and ts < cutoff
    returning 1)
  select count(*) into n from del;
  return n;
end $$;
revoke all on function public.q_prune_inverter_history(bigint, integer) from public, anon, authenticated;
grant execute on function public.q_prune_inverter_history(bigint, integer) to service_role;

-- ── reader: 0046's, with 5-minute rows filling buckets that have no samples ──
create or replace function public.api_inverter_history(p_date date default null, p_plant bigint default null)
returns jsonb language sql stable security definer set search_path = public, private, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  d as (select coalesce(p_date, public.today_tz((select tz from pz))) as day),
  lo as (select public.day_start_epoch_tz((select day from d), (select tz from pz)) as t0),
  raw as (
    select t.sn, ((t.ts - (select t0 from lo)) / 300)::int as bkt, t.ts, t.ac_c, t.dc_c, t.vac_v, t.fac_hz, t.grid_fac_hz
      from public.inverter_history t, lo
     where t.plant_id = (select id from pl) and t.ts >= lo.t0 and t.ts < lo.t0 + 86400
  ),
  fromraw as (
    select sn, bkt, count(*)::int as n, count(dc_c)::int as dcn,
           max(ac_c) as ac, max(dc_c) as dc, min(dc_c) as dcmin,
           min(vac_v) as vmin, max(vac_v) as vmax,
           (array_agg(vac_v order by ts desc) filter (where vac_v is not null))[1] as v,
           min(fac_hz) as fmin, max(fac_hz) as fmax,
           min(grid_fac_hz) as gmin, max(grid_fac_hz) as gmax
      from raw group by sn, bkt
  ),
  b as (
    select * from fromraw
    union all
    select f.sn, ((f.ts - (select t0 from lo)) / 300)::int, f.n::int, case when f.dc_max is null then 0 else f.n::int end,
           f.ac_max, f.dc_max, f.dc_min, f.vac_min, f.vac_max, f.vac_last,
           f.fac_min, f.fac_max, f.gfac_min, f.gfac_max
      from public.inverter_history_5m f, lo
     where f.plant_id = (select id from pl) and f.ts >= lo.t0 and f.ts < lo.t0 + 86400
       and not exists (select 1 from fromraw r
                        where r.sn = f.sn and r.bkt = ((f.ts - lo.t0) / 300)::int)
  ),
  sns as (
    select r.sn, coalesce(nullif(m.alias, ''), r.sn) as alias
      from (select distinct sn from b) r left join private.meta m on m.sn = r.sn
  )
  select jsonb_build_object(
    'date', (select day from d)::text,
    'inverters', coalesce((select jsonb_agg(jsonb_build_object(
        'sn', s.sn, 'alias', s.alias,
        'dcFlat', (select sum(x.dcn) > 1 and min(x.dcmin) = max(x.dc) from b x where x.sn = s.sn),
        'last', (select public._hm(max(bkt)) from b x where x.sn = s.sn),
        'points', (select jsonb_agg(jsonb_build_object('time', public._hm(g.i),
                     'ac', x.ac, 'dc', x.dc, 'vmin', x.vmin, 'vmax', x.vmax, 'v', x.v,
                     'fmin', x.fmin, 'fmax', x.fmax, 'gmin', x.gmin, 'gmax', x.gmax) order by g.i)
                     from generate_series(0, 287) g(i) left join b x on x.sn = s.sn and x.bkt = g.i)
      ) order by s.alias) from sns s), '[]'::jsonb))
$$;
revoke all on function public.api_inverter_history(date, bigint) from public, anon;
grant execute on function public.api_inverter_history(date, bigint) to authenticated, service_role;

-- ── purge: 0070's body plus the new table ───────────────────────────────────
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

  delete from public.readings            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings', n);
  delete from public.strings             where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings', n);
  delete from public.readings_5m         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings_5m', n);
  delete from public.strings_5m          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings_5m', n);
  delete from public.agg_minute          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_minute', n);
  delete from public.plant_energy        where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_energy', n);
  delete from public.inverter_history    where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history', n);
  delete from public.inverter_history_5m where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history_5m', n);
  delete from public.grid_off            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('grid_off', n);
  delete from public.plant_config        where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from private.gaps               where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('gaps', n);
  delete from private.meta               where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  delete from private.grid_off_progress  where plant_id = p_plant;
  delete from private.plant_purge        where plant_id = p_plant;
  return out;
end $$;

-- Summarise what is already past 61 days (mid-July to early August on production).
do $$
declare p bigint; out jsonb := '{}'::jsonb;
begin
  for p in select distinct plant_id from public.inverter_history loop
    out := out || jsonb_build_object(p::text, public.q_prune_inverter_history(p));
  end loop;
  raise notice 'inverter_history summarised and deleted: %', out;
end $$;
