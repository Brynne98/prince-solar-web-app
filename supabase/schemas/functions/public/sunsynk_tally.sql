CREATE OR REPLACE FUNCTION public.sunsynk_tally(p_rows jsonb, p_shard integer, p_run_ms integer, p_plants integer)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  insert into private.sunsynk_calls as t (day, kind, result, calls, ms_total, ms_max, plants, last_at)
  select (now() at time zone 'Africa/Johannesburg')::date, x.kind, x.result,
         sum(x.calls), sum(x.ms), max(x.ms_max), sum(x.plants), now()
    from (select r.kind, r.result, r.calls, r.ms, r.ms_max, 0::bigint as plants
            from jsonb_to_recordset(coalesce(p_rows, '[]')) as r(kind text, result text, calls bigint, ms bigint, ms_max int)
           where r.kind is not null and r.result is not null
          union all
          select 'poll_run', 's' || p_shard, 1, p_run_ms, p_run_ms, p_plants
           where p_shard is not null) x
   group by x.kind, x.result
   order by x.kind, x.result
  on conflict (day, kind, result) do update set
    calls    = t.calls + excluded.calls,
    ms_total = t.ms_total + excluded.ms_total,
    ms_max   = greatest(t.ms_max, excluded.ms_max),
    plants   = t.plants + excluded.plants,
    last_at  = excluded.last_at;
$function$;
