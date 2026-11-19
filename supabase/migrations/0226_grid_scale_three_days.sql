-- SOLAR-594: q_grid_feed_scale timed out (8 s statement_timeout on authenticator)
-- 6 times from 17 to 19 Nov, so sync-plant-energy used a grid multiplier of 1.
--
-- Cause: it counted inverters over 30 daily readings partitions. Each cold day
-- partition costs ~200-480 ms of heap reads for one plant (~2,880 rows a day for
-- two inverters, spread over pages shared with every other plant). 538820 with
-- 8 days of data took 2.4 s cold; a plant with a full 30 days goes past 8 s.
--
-- Fix: look back 3 days, not 30. grid_import_total_kwh is a lifetime counter, so
-- one day of rows already shows which inverters carry a CT. 3 days keeps the
-- answer right through a 2-day slave outage; a longer one halves grid for those
-- runs, and the next run after it comes back puts the right figure back.
create or replace function public.q_grid_feed_scale(p_plant bigint)
returns double precision
language sql stable
set search_path = public, pg_temp
as $$
  with n as (
    select count(distinct sn) as inv,
           count(distinct sn) filter (where grid_import_total_kwh > 0) as ct
      from public.readings
     where plant_id = p_plant and ts >= extract(epoch from now())::bigint - 3 * 86400
  )
  select case when inv > 0 and ct > 0 then inv::double precision / ct else 1 end from n
$$;
revoke all on function public.q_grid_feed_scale(bigint) from public, anon, authenticated;
grant execute on function public.q_grid_feed_scale(bigint) to service_role;
