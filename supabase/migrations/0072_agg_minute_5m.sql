-- ============================================================================
-- 0072 — the plant's minute history: every minute for 60 days, then 5-minute
-- rows forever (SOLAR-62).
--
-- agg_minute (solar, home, battery, grid, SoC per plant per minute) was kept
-- forever at minute detail: ~83 MB per home a year. Every past-day chart
-- already draws 5-minute buckets (q_day_agg), so minutes older than 61 days
-- are summarised into agg_5m and deleted. 61, not 60: recover's backfill and
-- the new-link backfill reach back at most 60 days, so a thinned day is never
-- refilled. Decided by Brynne, 2026-10-05 (SOLAR-43 review, option A).
--
-- A 5-minute row: avg / min / max of each value (avg is what the chart draws;
-- energy is avg x n x 60 s), grid import/export and battery +/- averaged apart,
-- n minutes and n_poller (the rest came from recover's backfill, which the
-- chart marks as estimated).
--
-- Readers that look past 60 days now read both tables:
--   * q_day_agg fills a bucket with no minutes from its agg_5m row, so
--     api_history draws an old day exactly as before;
--   * q_day_gap_minutes, q_recovered_minutes and q_stats count summarised
--     minutes as well, so an old day shows no false "missing" shading and the
--     history-day count does not shrink.
-- Everything else reads 30 days or less. The weekly forecast fit
-- (q_forecast_cal_*) now sees 60 days of minutes instead of 120; the forecast
-- itself is being removed (SOLAR-64).
--
-- batt_sign_detect() flips agg_minute.batt_w for rows since the plant's last
-- sign decision. That decision is made in a plant's first days, so it never
-- reaches rows old enough to be summarised; agg_5m is not flipped.
-- ============================================================================

create table if not exists public.agg_5m (
  plant_id        bigint   not null,
  ts              bigint   not null,     -- bucket start, epoch seconds, multiple of 300
  n               smallint not null,     -- minutes summarised
  n_poller        smallint not null,     -- of which logged live; the rest are backfill
  pv_w_avg        real, pv_w_min   real, pv_w_max   real,
  load_w_avg      real, load_w_min real, load_w_max real,
  batt_w_avg      real, batt_w_min real, batt_w_max real,
  grid_w_avg      real, grid_w_min real, grid_w_max real,
  soc_avg         real, soc_min    real, soc_max    real,
  grid_in_w_avg   real,
  grid_out_w_avg  real,
  batt_pos_w_avg  real,
  batt_neg_w_avg  real,
  primary key (plant_id, ts)
);
comment on table public.agg_5m is
  'agg_minute older than 61 days, one row per plant per 5 minutes: avg/min/max of each value, minute counts. Written by private.agg_minute_rollup (SOLAR-62).';

alter table public.agg_5m enable row level security;
drop policy if exists agg_5m_read on public.agg_5m;
create policy agg_5m_read on public.agg_5m for select to authenticated
  using (plant_id in (select public.my_plant_ids()));

-- ── summarise, then delete ──────────────────────────────────────────────────
create or replace function private.agg_minute_rollup(p_days integer default 61)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  cutoff bigint := ((extract(epoch from now())::bigint - p_days * 86400) / 300) * 300;
  made bigint; gone bigint;
begin
  insert into public.agg_5m
    (plant_id, ts, n, n_poller,
     pv_w_avg, pv_w_min, pv_w_max, load_w_avg, load_w_min, load_w_max,
     batt_w_avg, batt_w_min, batt_w_max, grid_w_avg, grid_w_min, grid_w_max,
     soc_avg, soc_min, soc_max, grid_in_w_avg, grid_out_w_avg, batt_pos_w_avg, batt_neg_w_avg)
  select plant_id, (ts / 300) * 300, count(*),
         count(*) filter (where coalesce(source, 'poller') = 'poller'),
         avg(pv_w), min(pv_w), max(pv_w), avg(load_w), min(load_w), max(load_w),
         avg(batt_w), min(batt_w), max(batt_w), avg(grid_w), min(grid_w), max(grid_w),
         avg(soc), min(soc), max(soc),
         avg(greatest(grid_w, 0)), avg(greatest(-grid_w, 0)),
         avg(greatest(batt_w, 0)), avg(greatest(-batt_w, 0))
    from public.agg_minute
   where ts < cutoff and plant_id is not null
   group by plant_id, (ts / 300) * 300
  on conflict do nothing;
  get diagnostics made = row_count;

  delete from public.agg_minute where ts < cutoff and plant_id is not null;
  get diagnostics gone = row_count;
  return jsonb_build_object('buckets', made, 'minutes', gone);
end $$;
revoke all on function private.agg_minute_rollup(integer) from public, anon, authenticated;

-- ── readers ─────────────────────────────────────────────────────────────────
-- 0034's q_day_agg, with agg_5m filling buckets that have no minutes.
create or replace function public.q_day_agg(p_plant bigint, p_day date, p_source text default null)
returns table (hm text, pv_w numeric, load_w numeric, batt_w numeric, grid_w numeric, soc numeric, feed_n bigint, row_n bigint)
language sql stable set search_path = public, pg_temp
as $$
  with pz as (select public.plant_tz(p_plant) as tz),
  b as (select public.day_start_epoch_tz(p_day, (select tz from pz)) as lo),
  m as (
    select (a.ts - b.lo) / 300 as k,
           min(a.ts) as t,
           round(avg(a.pv_w)::numeric)   as pv_w,
           round(avg(a.load_w)::numeric) as load_w,
           round(avg(a.batt_w)::numeric) as batt_w,
           round(avg(a.grid_w)::numeric) as grid_w,
           round(avg(a.soc)::numeric)    as soc,
           sum(case when coalesce(a.source, 'poller') <> 'poller' then 1 else 0 end) as feed_n,
           count(*) as row_n
      from public.agg_minute a, b
     where a.plant_id = p_plant
       and a.ts >= b.lo and a.ts < b.lo + 86400
       and (p_source is null or a.source = p_source)
     group by (a.ts - b.lo) / 300
  ),
  f as (
    select (f.ts - b.lo) / 300 as k, f.ts as t,
           round(f.pv_w_avg::numeric), round(f.load_w_avg::numeric), round(f.batt_w_avg::numeric),
           round(f.grid_w_avg::numeric), round(f.soc_avg::numeric),
           (f.n - f.n_poller)::bigint, f.n::bigint
      from public.agg_5m f, b
     where f.plant_id = p_plant
       and f.ts >= b.lo and f.ts < b.lo + 86400
       and p_source is null          -- a 5-minute row mixes sources; every caller passes null
       and not exists (select 1 from m where m.k = (f.ts - b.lo) / 300)
  )
  select to_char(public.local_ts_tz(x.t, (select tz from pz)), 'HH24:MI'),
         x.pv_w, x.load_w, x.batt_w, x.grid_w, x.soc, x.feed_n, x.row_n
    from (select * from m union all select * from f) x
   order by x.t
$$;

-- 0028's, counting summarised minutes as present.
create or replace function public.q_day_gap_minutes(p_plant bigint, p_day date)
returns bigint language sql stable set search_path = public, pg_temp
as $$
  with pz as (select public.plant_tz(p_plant) as tz),
  b as (
    select least((select min(ts) from public.agg_minute where plant_id = p_plant),
                 (select min(ts) from public.agg_5m where plant_id = p_plant)) as first_ts,
           public.day_start_epoch_tz(p_day, (select tz from pz))          as day_start,
           extract(epoch from now())::bigint                              as now_ts
  ),
  w as (select greatest(day_start, first_ts) as lo, least(day_start + 86400, now_ts) as hi from b where first_ts is not null)
  select case when w.hi <= w.lo then null
              else greatest(0, round((w.hi - w.lo) / 60.0)::bigint
                   - (select count(*) from public.agg_minute where plant_id = p_plant and ts >= w.lo and ts < w.hi)
                   - (select coalesce(sum(n), 0) from public.agg_5m where plant_id = p_plant and ts >= w.lo and ts < w.hi))
         end
    from w
$$;

-- 0034's, counting summarised backfill minutes too.
create or replace function public.q_recovered_minutes(p_plant bigint, p_day date)
returns bigint language sql stable set search_path = public, pg_temp
as $$
  with b as (select public.day_start_epoch_tz(p_day, public.plant_tz(p_plant)) as lo)
  select (select count(*) from public.agg_minute a, b
           where a.plant_id = p_plant and coalesce(a.source, 'poller') <> 'poller'
             and a.ts >= b.lo and a.ts < b.lo + 86400)
       + (select coalesce(sum(f.n - f.n_poller), 0) from public.agg_5m f, b
           where f.plant_id = p_plant and f.ts >= b.lo and f.ts < b.lo + 86400)
$$;

-- 0028's, with summarised history counted in rows, days and the first reading.
create or replace function public.q_stats(p_plant bigint)
returns table (agg_rows bigint, days bigint, first_ts bigint, last_ts bigint, per_inverter_rows bigint)
language sql stable set search_path = public, pg_temp
as $$
  with pz as (select public.plant_tz(p_plant) as tz)
  select
    (select count(*) from public.agg_minute where plant_id = p_plant)
      + (select coalesce(sum(n), 0) from public.agg_5m where plant_id = p_plant)::bigint,
    (select count(distinct d) from (
        select public.local_day_tz(ts, (select tz from pz)) d from public.agg_minute where plant_id = p_plant
        union
        select public.local_day_tz(ts, (select tz from pz)) from public.agg_5m where plant_id = p_plant) x),
    least((select min(ts) from public.agg_minute where plant_id = p_plant),
          (select min(ts) from public.agg_5m where plant_id = p_plant)),
    (select max(ts) from public.agg_minute where plant_id = p_plant),
    (select count(*) from public.readings where plant_id = p_plant)
$$;

-- ── purge: 0071's body plus the new table ───────────────────────────────────
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
  delete from public.agg_5m              where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_5m', n);
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

-- ── schedule: daily 04:40 UTC, after the partition rollup ───────────────────
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping agg-minute-rollup job (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'agg-minute-rollup') then
    perform cron.unschedule('agg-minute-rollup');
  end if;
  perform cron.schedule('agg-minute-rollup', '40 4 * * *', 'select private.agg_minute_rollup(61)');
end $$;

-- Summarise what is already past 61 days (30 May to early August on production).
do $$
begin
  raise notice 'agg_minute_rollup: %', private.agg_minute_rollup(61);
end $$;
