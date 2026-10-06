-- SOLAR-43: index size and use since stats reset, for the big tables. Read-only.
select s.relname tbl, s.indexrelname idx, pg_size_pretty(pg_relation_size(s.indexrelid)) size, s.idx_scan scans
  from pg_stat_user_indexes s
 where s.schemaname = 'public' and pg_relation_size(s.indexrelid) > 1000000
 order by pg_relation_size(s.indexrelid) desc
