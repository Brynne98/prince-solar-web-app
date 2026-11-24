-- ============================================================================
-- 0249 — less write churn on the minute tables (storage review, 2026-11-24).
--
-- 1. q_insert_inverter_history: the poller re-sends the whole of today's
--    temperature samples every 10 minutes and the upsert rewrote every row it
--    already held, changed or not (prod: 14.4 M updates against 5.9 M inserts).
--    A row is now rewritten only when the merge changes a value. The count
--    returned is rows written; callers only log it.
-- 2. agg_minute: two indexes no function reads. agg_minute_day_idx is on
--    local_day(ts), which nothing has queried since per-plant time zones (0028)
--    moved readers to local_day_tz; agg_minute_source_idx covers nearly every
--    row and every source filter also names plant_id, which the primary key
--    serves. 35 MB between them.
-- 3. readings/strings day partitions 7 days ahead, not 3 (0088). A week of missed
--    03:00 runs before writes fail; the hot per-minute readers are plpgsql and
--    prune at plan time, so the 4 extra empty days cost them nothing.
-- 4. public.job_check_partitions(): how many UTC days from today each table
--    covers without a gap, for job-check's partitions:<table> check.
-- ============================================================================

-- ── 1. write a held row only when something changes ────────────────────────
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
    insert into public.inverter_history as h (plant_id, sn, ts, ac_c, dc_c, vac_v, fac_hz, grid_fac_hz)
    select p_plant, p_sn, ts, ac_c, dc_c, vac_v, fac_hz, grid_fac_hz from src
    on conflict (sn, ts) do update
      set ac_c        = coalesce(excluded.ac_c,        h.ac_c),
          dc_c        = coalesce(excluded.dc_c,        h.dc_c),
          vac_v       = coalesce(excluded.vac_v,       h.vac_v),
          fac_hz      = coalesce(excluded.fac_hz,      h.fac_hz),
          grid_fac_hz = coalesce(excluded.grid_fac_hz, h.grid_fac_hz),
          plant_id    = excluded.plant_id
      where (h.plant_id, h.ac_c, h.dc_c, h.vac_v, h.fac_hz, h.grid_fac_hz)
            is distinct from
            (excluded.plant_id,
             coalesce(excluded.ac_c,        h.ac_c),
             coalesce(excluded.dc_c,        h.dc_c),
             coalesce(excluded.vac_v,       h.vac_v),
             coalesce(excluded.fac_hz,      h.fac_hz),
             coalesce(excluded.grid_fac_hz, h.grid_fac_hz))
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;
revoke all on function public.q_insert_inverter_history(bigint, text, jsonb) from public, anon, authenticated;
grant execute on function public.q_insert_inverter_history(bigint, text, jsonb) to service_role;

-- ── 2. unread agg_minute indexes ────────────────────────────────────────────
drop index if exists public.agg_minute_day_idx;
drop index if exists public.agg_minute_source_idx;

-- ── 3. partitions 7 days ahead ──────────────────────────────────────────────
-- Both callers (ensure-partitions at 03:00, rollup_old_days at 04:30) take the default.
create or replace function private.ensure_partitions(p_days_ahead integer default 7)
returns integer
language plpgsql
set search_path = pg_temp
as $$
declare t text; d date; made int := 0;
begin
  foreach t in array array['readings', 'strings'] loop
    for d in select generate_series((now() at time zone 'UTC')::date::timestamp,
                                    ((now() at time zone 'UTC')::date + p_days_ahead)::timestamp, interval '1 day')::date loop
      if private.ensure_day_partition(t, d) then made := made + 1; end if;
    end loop;
  end loop;
  return made;
end $$;
select private.ensure_partitions();

-- ── 4. partition coverage for job-check ─────────────────────────────────────
-- [{table, days}]: days = whole UTC days from today (today counted) that have a
-- partition, stopping at the first gap. 0 means today itself has none.
create or replace function public.job_check_partitions()
returns jsonb
language sql
stable
security definer
set search_path = pg_temp
as $$
  with b as (
    select p.relname as tbl,
           private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'FROM') as lo,
           private.partbound_epoch(pg_get_expr(ch.relpartbound, ch.oid), 'TO')   as hi
      from pg_inherits i
      join pg_class ch on ch.oid = i.inhrelid
      join pg_class p  on p.oid  = i.inhparent
     where i.inhparent in ('public.readings'::regclass, 'public.strings'::regclass)
  ),
  t0 as (select extract(epoch from (now() at time zone 'UTC')::date::timestamp at time zone 'UTC')::bigint as s),
  days as (
    select tbl, k
      from (values ('readings'), ('strings')) v(tbl), generate_series(0, 30) k, t0
     where exists (select 1 from b where b.tbl = v.tbl
                      and b.lo <= t0.s + k * 86400 and b.hi >= t0.s + (k + 1) * 86400)
  )
  select jsonb_agg(jsonb_build_object('table', v.tbl,
           'days', coalesce((select min(g) from generate_series(0, 31) g
                              where not exists (select 1 from days d where d.tbl = v.tbl and d.k = g)), 0))
           order by v.tbl)
    from (values ('readings'), ('strings')) v(tbl)
$$;
revoke all on function public.job_check_partitions() from public, anon, authenticated;
grant execute on function public.job_check_partitions() to service_role;
