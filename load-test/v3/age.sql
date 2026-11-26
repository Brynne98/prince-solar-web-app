-- SOLAR-681 R22: reading age at 500 logins. For each plant-minute the driver expected
-- (lt3.expected), when its login's save answered (private.poll_runs, commit_ms after the minute)
-- against when that plant's page asks: its own second, 12-42 s past the minute
-- (public/app.jsx, 12000 + (plantId * 7919 % 31) * 1000). LOCAL stack only.
--   psql "$DB" -v from=<epoch> -v to=<epoch> -f load-test/v3/age.sql
with saves as (
  select extract(epoch from r.minute)::bigint as ts, (x->>'account')::uuid as login, (x->>'commit_ms')::int as commit_ms
    from private.poll_runs r, jsonb_array_elements(r.logins) x
   where r.minute between to_timestamp(:from) and to_timestamp(:to) and x->>'commit_ms' is not null
), by_plant as (
  select e.ts, e.plant_id, min(s.commit_ms) as commit_ms, (12 + (e.plant_id * 7919 % 31)) * 1000 as asks_ms
    from lt3.expected e
    left join plants.login_plants lp on lp.plant = e.plant_id and lp.gone_at is null
    left join saves s on s.ts = e.ts and s.login = lp.login
   where e.ts between :from and :to
   group by e.ts, e.plant_id
)
select count(*) as plant_minutes,
       count(*) filter (where commit_ms is null) as no_save,
       count(*) filter (where commit_ms > asks_ms) as saved_after_page_asks,
       round(percentile_cont(0.95) within group (order by commit_ms)::numeric / 1000, 1) as save_p95_s,
       round(max(commit_ms)::numeric / 1000, 1) as save_max_s,
       min(asks_ms) / 1000 as earliest_page_s
  from by_plant;
