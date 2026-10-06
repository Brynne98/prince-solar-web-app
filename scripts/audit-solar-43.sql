-- SOLAR-43 storage audit. Read-only: one SELECT, no writes.
-- Run: supabase db query --linked -f scripts/audit-solar-43.sql
select jsonb_pretty(jsonb_build_object(
  'read_at', now(),
  'db_bytes', pg_database_size(current_database()),
  'plants', (select count(distinct plant_id) from public.plant_config),
  -- every table and partition in public and private, with its indexes and toast
  'tables', (select jsonb_agg(jsonb_build_object(
      'name', n.nspname || '.' || c.relname,
      'parent', (select p.relname from pg_inherits i join pg_class p on p.oid = i.inhparent where i.inhrelid = c.oid),
      'total_bytes', pg_total_relation_size(c.oid),
      'index_bytes', pg_indexes_size(c.oid),
      'est_rows', c.reltuples::bigint) order by pg_total_relation_size(c.oid) desc)
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where c.relkind = 'r' and n.nspname in ('public', 'private')),
  -- other schemas that take space (cron log, net responses, auth, storage)
  'other_schemas', (select jsonb_object_agg(nspname, bytes) from (
      select n.nspname, sum(pg_total_relation_size(c.oid)) bytes
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where c.relkind = 'r' and n.nspname not in ('public', 'private', 'pg_catalog', 'information_schema')
       group by 1 order by 2 desc) s),
  -- span and rows per plant per day over the last 7 full days
  'rate_7d', (select jsonb_agg(r) from (
      select 'readings' tbl, plant_id, count(*) / 7.0 rows_per_day, count(distinct sn) inverters
        from public.readings where ts >= extract(epoch from now() - interval '7 days') group by plant_id
      union all
      select 'strings', plant_id, count(*) / 7.0, count(distinct sn)
        from public.strings where ts >= extract(epoch from now() - interval '7 days') group by plant_id
      union all
      select 'agg_minute', plant_id, count(*) / 7.0, null
        from public.agg_minute where ts >= extract(epoch from now() - interval '7 days') group by plant_id
      union all
      select 'inverter_history', plant_id, count(*) / 7.0, count(distinct sn)
        from public.inverter_history where ts >= extract(epoch from now() - interval '7 days') group by plant_id
    ) r),
  'span', jsonb_build_object(
      'readings',      (select jsonb_build_object('min', to_timestamp(min(ts)), 'max', to_timestamp(max(ts))) from public.readings),
      'strings',       (select jsonb_build_object('min', to_timestamp(min(ts)), 'max', to_timestamp(max(ts))) from public.strings),
      'agg_minute',    (select jsonb_build_object('min', to_timestamp(min(ts)), 'max', to_timestamp(max(ts)), 'rows', count(*)) from public.agg_minute),
      'inverter_history', (select jsonb_build_object('min', to_timestamp(min(ts)), 'max', to_timestamp(max(ts)), 'rows', count(*)) from public.inverter_history),
      'plant_energy',  (select jsonb_build_object('min', min(period), 'max', max(period), 'rows', count(*)) from public.plant_energy),
      'client_errors', (select jsonb_build_object('min', min(at), 'max', max(at), 'rows', count(*)) from public.client_errors)),
  'partitions_dropped',   (select jsonb_agg(to_jsonb(d)) from private.partitions_dropped d),
  'strings_downsampled',  (select jsonb_agg(to_jsonb(d)) from private.strings_downsampled d),
  'cron', (select jsonb_agg(jsonb_build_object('job', jobname, 'schedule', schedule, 'active', active)) from cron.job),
  'cron_runs_7d', (select jsonb_agg(x) from (
      select j.jobname, count(*) runs, round(avg(extract(epoch from d.end_time - d.start_time))::numeric, 2) avg_s,
             count(*) filter (where d.status <> 'succeeded') failed
        from cron.job_run_details d join cron.job j using (jobid)
       where d.start_time > now() - interval '7 days' group by 1 order by 1) x),
  -- database time by statement since the last stats reset
  'stats_reset', (select stats_reset from pg_stat_statements_info),
  'top_statements', (select jsonb_agg(x) from (
      select left(regexp_replace(query, '\s+', ' ', 'g'), 120) q, calls,
             round(total_exec_time::numeric / 1000, 1) total_s, round(mean_exec_time::numeric, 1) mean_ms
        from pg_stat_statements order by total_exec_time desc limit 40) x)
)) as audit;
