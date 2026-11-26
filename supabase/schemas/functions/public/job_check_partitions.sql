CREATE OR REPLACE FUNCTION public.job_check_partitions()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
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
$function$;
