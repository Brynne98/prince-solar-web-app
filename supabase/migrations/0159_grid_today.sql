-- ============================================================================
-- 0159 — today's grid, live, for Equipment's Grid tile (SOLAR-398).
--
-- The tile drew grid voltage and "Off today" from SunSynk's inverter history,
-- which recover fetches every six hours, and public.grid_off is rebuilt once a
-- day (04:10). The poller already stores grid_volt_v per inverter per minute;
-- this reads it back for today in 5-minute steps, using the same presence rule
-- as grid_off (private.grid_minutes, 0069), so the tile and the outage list agree.
--
-- Read only: no table changes. Definer, like the other new api_* readers
-- (0066: invoker + RLS timed out over HTTP).
-- ============================================================================

create or replace function public.api_grid_today(p_plant bigint default null)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with p as (select public.my_plant(p_plant) as id),
  lo as (
    select p.id,
           extract(epoch from date_trunc('day', now() at time zone z.tz) at time zone z.tz)::bigint as t0
      from p
      cross join lateral (select coalesce((select c.timezone from public.plant_config c where c.plant_id = p.id),
                                          'Africa/Johannesburg') as tz) z
  ),
  m as (
    select g.ts, g.present
      from lo, private.grid_minutes(lo.id, lo.t0, extract(epoch from now())::bigint + 60) g
  ),
  v as (
    select ((r.ts - lo.t0) / 300)::int as b,
           avg(r.grid_volt_v) filter (where r.grid_volt_v > 100) as volt
      from lo join public.readings r on r.plant_id = lo.id and r.ts >= lo.t0
     group by 1
  ),
  o as (
    select ((m.ts - lo.t0) / 300)::int as b, bool_or(not m.present) as off
      from m, lo
     group by 1
  )
  select jsonb_build_object(
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'i', coalesce(v.b, o.b),
               'v', round(v.volt::numeric, 1),
               'off', coalesce(o.off, false))
             order by coalesce(v.b, o.b))
        from v full join o on o.b = v.b), '[]'::jsonb),
    'offMinutes', (select count(*) from m where not m.present)
  )
$$;
revoke all on function public.api_grid_today(bigint) from public, anon;
grant execute on function public.api_grid_today(bigint) to authenticated, service_role;
