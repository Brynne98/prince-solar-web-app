-- ============================================================================
-- 0036 — drop readings and strings partitions wholly older than 90 days.
--
-- Retention. Nothing reads per-inverter `readings` or per-string `strings`
-- rows beyond the latest minute and a short recent window (api_overview,
-- api_alerts_due, poll_commit); every chart, trend and period total reads
-- agg_minute (kept forever, 1/min plant sum) or plant_energy (cached kWh).
-- The raw tables are ~80% of the database, so this is what keeps the free
-- plan's 500 MB from filling in a few months.
--
-- private.drop_old_partitions(older_than_days)
--   Drops each child of readings/strings whose upper bound is at or before
--   now() - older_than_days. Each drop is logged in private.partitions_dropped
--   and its strings_downsampled row (if any) removed. A partition still
--   receiving writes is never a candidate: the live month's bound is in the
--   future. ensure_partitions() derives its earliest bound from the surviving
--   children, so it does not recreate what this dropped.
--
-- Cron: weekly, Sunday 04:30, after downsample-strings at 04:00 (04:00 thins
-- 90-day-old strings; 04:30 removes whatever is older still). Guarded like 0035.
-- The function is also run once at the end of this migration to free the
-- partitions already past the cutoff. Backup taken beforehand:
-- data/backup-2026-09-06-pre-partition-drop.sql (local, not committed).
-- ============================================================================

create table if not exists private.partitions_dropped (
  partition_name text primary key,
  dropped_at     timestamptz not null default now(),
  upper_bound    timestamptz not null,
  rows_dropped   bigint
);

create or replace function private.drop_old_partitions(p_older_than_days integer default 90)
returns jsonb
language plpgsql
set search_path = pg_temp
as $$
declare
  t text; c record;
  cutoff bigint := extract(epoch from now())::bigint - p_older_than_days * 86400;
  hi bigint; n bigint; done jsonb := '[]'::jsonb;
begin
  foreach t in array array['readings', 'strings'] loop
    for c in
      select ch.relname as name, pg_get_expr(ch.relpartbound, ch.oid) as bound
        from pg_inherits i join pg_class ch on ch.oid = i.inhrelid
       where i.inhparent = ('public.' || t)::regclass
       order by ch.relname
    loop
      hi := private.partbound_epoch(c.bound, 'TO');
      if hi > cutoff then continue; end if;

      execute format('select count(*) from public.%I', c.name) into n;
      execute format('drop table public.%I', c.name);
      insert into private.partitions_dropped (partition_name, upper_bound, rows_dropped)
      values (c.name, to_timestamp(hi), n)
      on conflict (partition_name) do update
        set dropped_at = now(), upper_bound = excluded.upper_bound, rows_dropped = excluded.rows_dropped;
      delete from private.strings_downsampled where partition_name = c.name;
      done := done || jsonb_build_object('partition', c.name, 'rows', n);
    end loop;
  end loop;
  return done;
end $$;

revoke all on function private.drop_old_partitions(integer) from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping drop-old-partitions job (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'drop-old-partitions') then perform cron.unschedule('drop-old-partitions'); end if;
  perform cron.schedule('drop-old-partitions', '30 4 * * 0', 'select private.drop_old_partitions(90)');
  raise notice 'scheduled drop-old-partitions (weekly, Sunday 04:30)';
exception when others then
  raise notice 'drop-old-partitions job skipped: %', sqlerrm;
end $$;

-- Free what is already past the cutoff.
do $$
declare r jsonb;
begin
  r := private.drop_old_partitions(90);
  raise notice 'drop_old_partitions: %', r;
end $$;
