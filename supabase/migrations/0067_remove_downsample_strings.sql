-- ============================================================================
-- 0067 — remove the downsample-strings job (SOLAR-59).
--
-- downsample_strings(90) (0035) thinned strings partitions wholly older than
-- 90 days at Sunday 04:00; drop_old_partitions(90) (0036) drops those same
-- partitions at 04:30. Every partition it could thin was gone half an hour
-- later, and its one run in the week to 5 Oct stopped at the 120 s limit:
-- private.strings_downsampled was empty, so it had never finished once.
--
-- Drops the job, the function and its log table. drop_old_partitions is
-- redefined without the line that cleared that log; otherwise unchanged and
-- still scheduled (SOLAR-60 replaces it with a 60-day 5-minute roll-up).
-- Unscheduling is a no-op where pg_cron is absent (the local stack).
-- ============================================================================
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - no downsample-strings job to remove (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'downsample-strings') then
    perform cron.unschedule('downsample-strings');
  end if;
end $$;

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
      done := done || jsonb_build_object('partition', c.name, 'rows', n);
    end loop;
  end loop;
  return done;
end $$;

revoke all on function private.drop_old_partitions(integer) from public, anon, authenticated;

drop function if exists private.downsample_strings(integer);
drop table if exists private.strings_downsampled;
