-- ============================================================================
-- 0044 — a newly linked plant gets its history at once, not a day later.
--
-- Until now a plant showed nothing but live numbers until the 02:15 energy sync
-- had run, and its minute history began at the first poll: `recover` only ever
-- scanned from the first poller row forward, and q_missing_minutes lower-bounded
-- at that row, so the two months SunSynk's per-inverter history holds were never
-- asked for.
--
-- Now:
--   * plant_config carries a backfill bookmark: `backfill_next` is the next local
--     day to fetch from per-inverter history, `backfill_until` the last. The seed
--     sets them to today-60 .. today-14 (the normal recover window starts at
--     today-13). `recover` walks the bookmark forward a few days per run. A day
--     that answers is never fetched twice; a day whose endpoints fail is retried
--     on the next run, and given up after a third failure so the walk cannot stall.
--     Both dates clear when done.
--   * q_missing_minutes reports every minute of a day that precedes the first
--     poller row while a backfill is pending.
--   * plant_bootstrap_kick(plant) fires sync-plant-energy and recover for that one
--     plant through pg_net, the same way the cron does — the link request returns
--     at once and the isolate's lifetime is irrelevant. No-op on the local stack.
-- ============================================================================

alter table public.plant_config
  add column if not exists backfill_next  date,
  add column if not exists backfill_until date,
  add column if not exists backfill_tries smallint not null default 0;

comment on column public.plant_config.backfill_next is
  'Next local day to fetch from SunSynk per-inverter history; null = no backfill pending. Advanced by recover.';
comment on column public.plant_config.backfill_until is
  'Last local day of the pending backfill (inclusive). Cleared with backfill_next when done.';
comment on column public.plant_config.backfill_tries is
  'Failed attempts at backfill_next so far; recover gives a day up after 3.';

-- Seed now stamps the backfill window on rows it creates. Never touches an
-- existing row (on conflict do nothing), so a relinked plant is not re-fetched.
create or replace function public.plant_config_seed(p_rows jsonb)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.plant_config (plant_id, timezone, currency, lat, lon, system_kwp, panel_azimuth, geometry_source,
                                   backfill_next, backfill_until)
  select (r->>'plant_id')::bigint,
         tz,
         coalesce(nullif(upper(r->>'currency'), ''), 'ZAR'),
         nullif(r->>'lat', '')::double precision,
         nullif(r->>'lon', '')::double precision,
         nullif(r->>'system_kwp', '')::double precision,
         -- north-facing south of the equator, south-facing north of it
         case when nullif(r->>'lat', '')::double precision > 0 then 180 else 0 end,
         'default',
         (now() at time zone tz)::date - 60,
         (now() at time zone tz)::date - 14
    from jsonb_array_elements(p_rows) r,
         lateral (select coalesce(nullif(r->>'timezone', ''), 'Africa/Johannesburg') as tz) z
  on conflict (plant_id) do nothing
$$;

-- Minutes of a day nobody has stored. While a backfill is pending, days before
-- the first poller row count too (the bound is the earlier of first_ts and the
-- backfill start); otherwise unchanged from 0028.
create or replace function public.q_missing_minutes(p_plant bigint, p_day date)
returns table (ts bigint) language sql stable set search_path = public, pg_temp
as $$
  with b as (
    select (select min(a.ts) from public.agg_minute a where a.plant_id = p_plant) as first_ts,
           (select public.day_start_epoch_tz(c.backfill_next, public.plant_tz(p_plant))
              from public.plant_config c where c.plant_id = p_plant and c.backfill_next is not null) as bf_ts,
           public.day_start_epoch_tz(p_day, public.plant_tz(p_plant))            as day_start,
           extract(epoch from now())::bigint                                    as now_ts
  ),
  bounds as (
    select ceil(greatest(day_start, least(first_ts, bf_ts)) / 60.0)::bigint * 60 as lo,
           least(day_start + 86400, now_ts - 600)                                as hi
      from b where first_ts is not null or bf_ts is not null
  )
  select g as ts from bounds, generate_series(bounds.lo, bounds.hi - 60, 60) g
   where bounds.hi > bounds.lo
     and not exists (select 1 from public.agg_minute a where a.plant_id = p_plant and a.ts = g)
   order by g
$$;

-- Plants linked before this migration with under two days of their own history
-- get the same window, so a deployment does not leave a just-linked plant out.
update public.plant_config c
   set backfill_next  = (now() at time zone c.timezone)::date - 60,
       backfill_until = (now() at time zone c.timezone)::date - 14
 where c.backfill_next is null
   and (select count(*) from public.agg_minute a where a.plant_id = c.plant_id) < 2 * 1440;

-- Fire the two batch functions for one plant. Same transport and credential as
-- the schedule (0009): pg_net + the vault service key. Where pg_net is absent
-- (local stack) it does nothing and says so; invoke the functions by hand there.
create or replace function public.plant_bootstrap_kick(p_plant bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  fn_base text := 'https://pmakzojwhouamawgszrc.functions.supabase.co';
  fn text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net not enabled here - not kicking bootstrap for plant %', p_plant;
    return;
  end if;
  foreach fn in array array['sync-plant-energy', 'recover'] loop
    perform net.http_post(
      url := fn_base || '/' || fn || '?plant=' || p_plant,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        'Content-Type', 'application/json'),
      body := '{}'::jsonb,
      timeout_milliseconds := 150000);
  end loop;
end $$;
revoke all on function public.plant_bootstrap_kick(bigint) from public, anon, authenticated;
grant execute on function public.plant_bootstrap_kick(bigint) to service_role;
