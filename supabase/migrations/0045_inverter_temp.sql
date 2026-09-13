-- ============================================================================
-- 0045 — inverter temperature history.
--
-- SunSynk's per-inverter `output/day` history carries two series the realtime
-- endpoints do not: DC TEMP (`dc_temp`) and AC TEMP (`igbt_temp`), at the
-- datalogger's own cadence, two months back (API.md, "Endpoint survey — 13 Sep
-- 2026"). Nothing live reports an inverter temperature on the official key, so
-- this is history-only: `recover` fetches it every run (today, plus a watermark
-- walk over the past) and the History tab draws it under the day chart.
--
--   * inverter_temp: one row per inverter per 5-minute bucket, the MAX of the
--     samples in it (peaks are what an overheat check wants; the mean hides them).
--     Per inverter, not per plant — agg_minute sums across inverters and cannot
--     hold this grain.
--   * plant_config.temp_next: next local day the walk fetches. Seeded at today-60
--     (what the cloud keeps); today is refetched every run and never advances it.
--   * q_insert_inverter_temp: bucket + upsert, service_role only.
--   * api_inverter_temps(p_date, p_plant): 288 buckets per inverter with nulls,
--     the same grid as api_history so the two charts align by index.
-- ============================================================================
create table if not exists public.inverter_temp (
  plant_id bigint not null,
  sn       text   not null,
  ts       bigint not null,            -- 5-minute bucket start, epoch seconds
  ac_c     real,                       -- AC TEMP (igbt_temp), max over the bucket
  dc_c     real,                       -- DC TEMP (dc_temp), max over the bucket
  primary key (sn, ts)
);
create index if not exists inverter_temp_plant_ts on public.inverter_temp (plant_id, ts);
comment on table public.inverter_temp is
  'Inverter AC/DC temperature from SunSynk output/day history, max per 5-minute bucket. Written by recover.';

alter table public.inverter_temp enable row level security;
drop policy if exists inverter_temp_read on public.inverter_temp;
create policy inverter_temp_read on public.inverter_temp for select to authenticated
  using (plant_id in (select public.my_plant_ids()));

alter table public.plant_config
  add column if not exists temp_next  date,
  add column if not exists temp_tries smallint not null default 0;
comment on column public.plant_config.temp_next is
  'Next local day recover fetches inverter temperatures for; null = walk not started. Today never advances it.';
comment on column public.plant_config.temp_tries is
  'Failed attempts at temp_next so far; recover steps past the day after 3 so one dead serial cannot stall the walk.';

-- Existing plants start at what the cloud still holds.
update public.plant_config c
   set temp_next = (now() at time zone c.timezone)::date - 60
 where c.temp_next is null;

-- New plants get the same start. Body otherwise 0044's.
create or replace function public.plant_config_seed(p_rows jsonb)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.plant_config (plant_id, timezone, currency, lat, lon, system_kwp, panel_azimuth, geometry_source,
                                   backfill_next, backfill_until, temp_next)
  select (r->>'plant_id')::bigint,
         tz,
         coalesce(nullif(upper(r->>'currency'), ''), 'ZAR'),
         nullif(r->>'lat', '')::double precision,
         nullif(r->>'lon', '')::double precision,
         nullif(r->>'system_kwp', '')::double precision,
         case when nullif(r->>'lat', '')::double precision > 0 then 180 else 0 end,
         'default',
         (now() at time zone tz)::date - 60,
         (now() at time zone tz)::date - 14,
         (now() at time zone tz)::date - 60
    from jsonb_array_elements(p_rows) r,
         lateral (select coalesce(nullif(r->>'timezone', ''), 'Africa/Johannesburg') as tz) z
  on conflict (plant_id) do nothing
$$;

-- Rows are {ts, ac, dc} with ts in epoch seconds (any cadence); bucketed here.
-- A refetch of a day (today grows through the day) keeps the higher reading.
create or replace function public.q_insert_inverter_temp(p_plant bigint, p_sn text, p_rows jsonb)
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare n integer;
begin
  with src as (
    select (r->>'ts')::bigint / 300 * 300 as ts,
           max(nullif(r->>'ac', '')::real) as ac_c,
           max(nullif(r->>'dc', '')::real) as dc_c
      from jsonb_array_elements(p_rows) r
     group by 1
  ),
  ins as (
    insert into public.inverter_temp (plant_id, sn, ts, ac_c, dc_c)
    select p_plant, p_sn, ts, ac_c, dc_c from src
    on conflict (sn, ts) do update
      set ac_c = greatest(public.inverter_temp.ac_c, excluded.ac_c),
          dc_c = greatest(public.inverter_temp.dc_c, excluded.dc_c),
          plant_id = excluded.plant_id
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;
revoke all on function public.q_insert_inverter_temp(bigint, text, jsonb) from public, anon, authenticated;
grant execute on function public.q_insert_inverter_temp(bigint, text, jsonb) to service_role;

-- Per-inverter day series on the api_history grid. `dcFlat` says the DC sensor
-- never moved all day (the parents' inverters report a constant 25 °C): the chart
-- hides that line. `last` is the latest bucket with data, the lag readout.
create or replace function public.api_inverter_temps(p_date date default null, p_plant bigint default null)
returns jsonb language sql stable security definer set search_path = public, private, pg_temp
as $$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  d as (select coalesce(p_date, public.today_tz((select tz from pz))) as day),
  lo as (select public.day_start_epoch_tz((select day from d), (select tz from pz)) as t0),
  rows_ as (
    select t.sn, ((t.ts - (select t0 from lo)) / 300)::int as bkt, t.ac_c, t.dc_c
      from public.inverter_temp t, lo
     where t.plant_id = (select id from pl) and t.ts >= lo.t0 and t.ts < lo.t0 + 86400
  ),
  sns as (
    select r.sn, coalesce(nullif(m.alias, ''), r.sn) as alias
      from (select distinct sn from rows_) r left join private.meta m on m.sn = r.sn
  )
  select jsonb_build_object(
    'date', (select day from d)::text,
    'inverters', coalesce((select jsonb_agg(jsonb_build_object(
        'sn', s.sn, 'alias', s.alias,
        'dcFlat', (select count(*) > 1 and min(dc_c) = max(dc_c) from rows_ r where r.sn = s.sn and r.dc_c is not null),
        'last', (select public._hm(max(bkt)) from rows_ r where r.sn = s.sn),
        'points', (select jsonb_agg(jsonb_build_object('time', public._hm(g.i), 'ac', r.ac_c, 'dc', r.dc_c) order by g.i)
                     from generate_series(0, 287) g(i) left join rows_ r on r.sn = s.sn and r.bkt = g.i)
      ) order by s.alias) from sns s), '[]'::jsonb))
$$;
revoke all on function public.api_inverter_temps(date, bigint) from public, anon;
grant execute on function public.api_inverter_temps(date, bigint) to authenticated, service_role;
