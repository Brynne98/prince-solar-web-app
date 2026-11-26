CREATE OR REPLACE FUNCTION private.fn_call_states()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  -- plpgsql, not sql: net._http_response is missing on the local stack, and a sql body is
  -- checked when it is created.
  return (with c as (
    select f.fn, f.shard, f.at, f.id, f.timeout_ms,
           r.id is not null as answered,
           case when r.id is null then 'no answer'
                when r.timed_out then 'timeout'
                when r.error_msg is not null then 'error'
                when r.status_code between 200 and 299 then null
                else r.status_code::text end as bad,
           left(coalesce(r.error_msg, ''), 200) as error
      from private.fn_calls f
      left join net._http_response r on r.id = f.id
     where f.at > now() - interval '5 hours'
  ), last as (
    select distinct on (fn, shard) *
      from c
     where answered or at < now() - timeout_ms * interval '1 millisecond' - interval '2 minutes'
     order by fn, shard, at desc
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'fn', fns.fn,
           'failing', (select bool_or(l.bad is not null) from last l where l.fn = fns.fn),
           'result', (select string_agg(distinct l.bad, ',') from last l where l.fn = fns.fn),
           'error', (select max(nullif(l.error, '')) from last l where l.fn = fns.fn and l.bad is not null),
           'last_call', (select max(l.at) from last l where l.fn = fns.fn),
           'failed_1h', (select count(*) from c where c.fn = fns.fn and c.bad is not null and c.answered
                                                  and c.at > now() - interval '1 hour'))
           order by fns.fn), '[]')
    from (select distinct fn from private.fn_calls where at > now() - interval '2 days') fns);
end $function$;
