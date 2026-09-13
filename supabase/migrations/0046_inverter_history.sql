-- ============================================================================
-- 0046 — inverter_temp becomes inverter_history: every device sample, plus AC
-- voltage, AC frequency and grid frequency.
--
-- 0045 kept inverter temperature as a 5-minute max per bucket. Voltage wants the
-- lowest reading in a window and frequency the spread, and each new series would
-- have needed a refetch, so the table now holds the datalogger's own samples
-- (~67 s on the masters, 5 min on the slaves; ~4,500 rows a day over both plants,
-- 60 days kept by the walk) and the read RPC buckets at read time, per series.
--
--   * inverter_history: ts = the device's sample time. ac_c / dc_c as before;
--     vac_v and fac_hz from output/day (vac1, fac: the inverter's AC terminal,
--     which reads the grid when tied and its own output when islanded);
--     grid_fac_hz from grid/day (fac: F-grid, 0 during an outage — the one series
--     that tells a blackout from a healthy terminal).
--   * The 0045 rows were bucket maxima, not samples: dropped, and the walk reset
--     to today-60 so both plants refill from the cloud over the next few runs.
--   * q_insert_inverter_history replaces q_insert_inverter_temp: a refetch
--     replaces what it carries and keeps what it lacks (coalesce).
--   * api_inverter_history: 288 buckets per inverter, per series — max temp,
--     min/max/last voltage, min/max frequency, min/max grid frequency.
--     api_inverter_temps stays as a wrapper until the frontend that calls it has
--     shipped (the two halves deploy separately); 0047 may drop it.
-- ============================================================================
alter table if exists public.inverter_temp rename to inverter_history;
alter index if exists inverter_temp_plant_ts rename to inverter_history_plant_ts;
do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'inverter_history' and policyname = 'inverter_temp_read') then
    alter policy inverter_temp_read on public.inverter_history rename to inverter_history_read;
  end if;
end $$;
alter table public.inverter_history
  add column if not exists vac_v       real,   -- V-ac-1 (vac1), the AC terminal
  add column if not exists fac_hz      real,   -- F-ac (fac) on output/day
  add column if not exists grid_fac_hz real;   -- F-grid (fac) on grid/day
comment on table public.inverter_history is
  'Per-inverter samples from SunSynk output/day and grid/day history at the device''s own cadence: AC/DC temperature, AC terminal voltage and frequency, grid frequency. Written by recover.';
comment on column public.inverter_history.ts is 'Device sample time, epoch seconds (0045 stored 5-minute bucket starts; those rows were dropped in 0046).';

-- Bucket maxima are not samples: start again from the cloud.
truncate public.inverter_history;
update public.plant_config c
   set temp_next = (now() at time zone c.timezone)::date - 60,
       temp_tries = 0;

drop function if exists public.q_insert_inverter_temp(bigint, text, jsonb);
-- Rows are {ts, ac, dc, vac, fac, gfac}; any field may be absent. A row already
-- there keeps the fields this fetch did not carry.
create or replace function public.q_insert_inverter_history(p_plant bigint, p_sn text, p_rows jsonb)
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare n integer;
begin
  with src as (
    -- one row per ts (ON CONFLICT cannot touch a row twice); duplicates merge per field
    select (r->>'ts')::bigint                  as ts,
           max(nullif(r->>'ac', '')::real)    as ac_c,
           max(nullif(r->>'dc', '')::real)    as dc_c,
           max(nullif(r->>'vac', '')::real)   as vac_v,
           max(nullif(r->>'fac', '')::real)   as fac_hz,
           max(nullif(r->>'gfac', '')::real)  as grid_fac_hz
      from jsonb_array_elements(p_rows) r
     where (r->>'ts') ~ '^\d+$'
     group by 1
  ),
  ins as (
    insert into public.inverter_history (plant_id, sn, ts, ac_c, dc_c, vac_v, fac_hz, grid_fac_hz)
    select p_plant, p_sn, ts, ac_c, dc_c, vac_v, fac_hz, grid_fac_hz from src
    on conflict (sn, ts) do update
      set ac_c        = coalesce(excluded.ac_c,        public.inverter_history.ac_c),
          dc_c        = coalesce(excluded.dc_c,        public.inverter_history.dc_c),
          vac_v       = coalesce(excluded.vac_v,       public.inverter_history.vac_v),
          fac_hz      = coalesce(excluded.fac_hz,      public.inverter_history.fac_hz),
          grid_fac_hz = coalesce(excluded.grid_fac_hz, public.inverter_history.grid_fac_hz),
          plant_id    = excluded.plant_id
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;
revoke all on function public.q_insert_inverter_history(bigint, text, jsonb) from public, anon, authenticated;
grant execute on function public.q_insert_inverter_history(bigint, text, jsonb) to service_role;

-- Nothing else prunes this table and the walk only writes; recover calls this once
-- a run. 120 days: twice what the cloud keeps, so a refill can never outrun it.
create or replace function public.q_prune_inverter_history(p_plant bigint, p_days integer default 120)
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare n integer;
begin
  with del as (
    delete from public.inverter_history
     where plant_id = p_plant and ts < extract(epoch from now())::bigint - p_days * 86400
    returning 1)
  select count(*) into n from del;
  return n;
end $$;
revoke all on function public.q_prune_inverter_history(bigint, integer) from public, anon, authenticated;
grant execute on function public.q_prune_inverter_history(bigint, integer) to service_role;

-- One day, 288 five-minute buckets per inverter, aggregated per series before the
-- grid join (raw rows would otherwise fan out to one point per sample):
--   ac, dc      max °C in the bucket
--   vmin/vmax/v lowest, highest and last voltage
--   fmin/fmax   AC frequency spread;  gmin/gmax  grid frequency spread
-- `dcFlat`: the DC sensor never moved all day (a constant 25 °C = no sensor).
-- `last`: latest bucket with any sample, the lag readout.
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
  b as (
    select sn, bkt,
           max(ac_c) as ac, max(dc_c) as dc,
           min(vac_v) as vmin, max(vac_v) as vmax,
           (array_agg(vac_v order by ts desc) filter (where vac_v is not null))[1] as v,
           min(fac_hz) as fmin, max(fac_hz) as fmax,
           min(grid_fac_hz) as gmin, max(grid_fac_hz) as gmax
      from raw group by sn, bkt
  ),
  sns as (
    select r.sn, coalesce(nullif(m.alias, ''), r.sn) as alias
      from (select distinct sn from raw) r left join private.meta m on m.sn = r.sn
  )
  select jsonb_build_object(
    'date', (select day from d)::text,
    'inverters', coalesce((select jsonb_agg(jsonb_build_object(
        'sn', s.sn, 'alias', s.alias,
        'dcFlat', (select count(*) > 1 and min(dc_c) = max(dc_c) from raw r where r.sn = s.sn and r.dc_c is not null),
        'last', (select public._hm(max(bkt)) from raw r where r.sn = s.sn),
        'points', (select jsonb_agg(jsonb_build_object('time', public._hm(g.i),
                     'ac', x.ac, 'dc', x.dc, 'vmin', x.vmin, 'vmax', x.vmax, 'v', x.v,
                     'fmin', x.fmin, 'fmax', x.fmax, 'gmin', x.gmin, 'gmax', x.gmax) order by g.i)
                     from generate_series(0, 287) g(i) left join b x on x.sn = s.sn and x.bkt = g.i)
      ) order by s.alias) from sns s), '[]'::jsonb))
$$;
revoke all on function public.api_inverter_history(date, bigint) from public, anon;
grant execute on function public.api_inverter_history(date, bigint) to authenticated, service_role;

-- Same shape as before plus the new keys; the pre-0046 page keeps working.
create or replace function public.api_inverter_temps(p_date date default null, p_plant bigint default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp
as $$ select public.api_inverter_history(p_date, p_plant) $$;
