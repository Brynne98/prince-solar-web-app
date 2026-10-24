-- ============================================================================
-- 0098 — a day counts for the date bars only when it has readings. (SOLAR-175)
--
-- 0080 counted a day when its daily total held any solar or use. A link pulls daily
-- totals for the plant's whole life but readings only 60 days back, so 538820 could
-- pick 27 May to 23 Aug and every day view said "No readings for this day". The day
-- views draw from readings (q_day_agg: agg_minute, then agg_5m), and api_history
-- draws nothing until a day has more than 5 five-minute buckets. A day now counts on
-- that same test: a day that can't fill the page can't be picked.
--
-- Same shape as 0080: ["YYYY-MM-DD", ...] oldest first, in the plant's own calendar;
-- security definer, my_plant(p_plant) raises unless auth.uid() is linked.
-- ============================================================================

create or replace function public.api_data_days(p_plant bigint default null)
returns jsonb
language sql
stable
security definer
set search_path to public, pg_temp
as $fn$
  with pl as (select public.my_plant(p_plant) as id),
  tz as (select public.plant_tz((select id from pl)) as tz),
  b as (
    select a.ts / 300 as k from public.agg_minute a where a.plant_id = (select id from pl)
    union
    select f.ts / 300 from public.agg_5m f where f.plant_id = (select id from pl)
  ),
  days as (
    select public.local_ts_tz(b.k * 300, (select tz from tz))::date as d
      from b
     group by 1
    having count(*) > 5
  )
  select coalesce(jsonb_agg(to_char(d, 'YYYY-MM-DD') order by d), '[]'::jsonb) from days
$fn$;

revoke all on function public.api_data_days(bigint) from public, anon;
grant execute on function public.api_data_days(bigint) to authenticated, service_role;
