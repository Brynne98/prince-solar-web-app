-- SOLAR-43: database time per RPC since the stats reset. Read-only.
select coalesce(substring(query from '"public"\."([a-z_0-9]+)"'), substring(query from 'public\.([a-z_0-9]+)\('), left(regexp_replace(query, '\s+', ' ', 'g'), 50)) fn,
       sum(calls) calls, round(sum(total_exec_time)::numeric / 1000) total_s,
       round((sum(total_exec_time) / nullif(sum(calls), 0))::numeric, 1) mean_ms, round(max(max_exec_time)::numeric) max_ms
  from pg_stat_statements
 group by 1 order by 3 desc limit 45
