-- ============================================================================
-- 0034 — recover from per-inverter history.
--
-- `recover` backfilled logger-offline minutes from the PLANT feed, whose scaling
-- has changed under us before (DATA_PIPELINE §3.2) and which only holds ~2 weeks.
-- SunSynk's per-inverter `…/day` history (API.md survey, 5 Sep 2026) gives grid,
-- load and SoC directly, PV from string V×I, and keeps 2+ months. The function
-- now rebuilds the spine per inverter and sums it, falling back to the plant feed
-- only for minutes the history cannot fill.
--
-- 1. q_insert_recovered gains p_source ('plantfeed' default, or 'invhistory').
-- 2. plant_inverters(): the sns the poller has seen for a plant (private.inverters).
-- 3. q_day_agg / q_recovered_minutes: "recovered" means any non-poller source, so
--    invhistory rows count as recovered and api_history draws them dotted (`est`).
-- ============================================================================

drop function if exists public.q_insert_recovered(bigint, jsonb);
create or replace function public.q_insert_recovered(p_plant bigint, p_rows jsonb, p_source text default 'plantfeed')
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare n integer;
begin
  if p_source not in ('plantfeed', 'invhistory') then
    raise exception 'q_insert_recovered: unknown source %', p_source;
  end if;
  with ins as (
    insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
    select p_plant, (r->>'ts')::bigint,
           nullif(r->>'pv_w','')::integer,   nullif(r->>'load_w','')::integer,
           nullif(r->>'batt_w','')::integer, nullif(r->>'grid_w','')::integer,
           nullif(r->>'soc','')::integer,    p_source
      from jsonb_array_elements(p_rows) r
    on conflict (plant_id, ts) do nothing
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;

create or replace function public.plant_inverters(p_plant bigint)
returns table (sn text)
language sql
stable
security definer
set search_path = private, pg_temp
as $$
  select i.sn from private.inverters i where i.plant_id = p_plant order by i.sn
$$;
revoke all on function public.plant_inverters(bigint) from public, anon, authenticated;
grant execute on function public.plant_inverters(bigint) to service_role;

-- q_day_agg: 0028's body; feed_n counts every non-poller row.
create or replace function public.q_day_agg(p_plant bigint, p_day date, p_source text default null)
returns table (hm text, pv_w numeric, load_w numeric, batt_w numeric, grid_w numeric, soc numeric, feed_n bigint, row_n bigint)
language sql stable set search_path = public, pg_temp
as $$
  with pz as (select public.plant_tz(p_plant) as tz),
  b as (select public.day_start_epoch_tz(p_day, (select tz from pz)) as lo)
  select to_char(public.local_ts_tz(min(a.ts), (select tz from pz)), 'HH24:MI') as hm,
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
   order by min(a.ts)
$$;

create or replace function public.q_recovered_minutes(p_plant bigint, p_day date)
returns bigint language sql stable set search_path = public, pg_temp
as $$
  with b as (select public.day_start_epoch_tz(p_day, public.plant_tz(p_plant)) as lo)
  select count(*) from public.agg_minute a, b
   where a.plant_id = p_plant and coalesce(a.source, 'poller') <> 'poller'
     and a.ts >= b.lo and a.ts < b.lo + 86400
$$;

-- q_insert_recovered was service_role only (0025); the new signature must be too.
revoke all on function public.q_insert_recovered(bigint, jsonb, text) from public, anon, authenticated;
grant execute on function public.q_insert_recovered(bigint, jsonb, text) to service_role;
