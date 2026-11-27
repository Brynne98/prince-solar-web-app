CREATE OR REPLACE FUNCTION history.next_due(p_at timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select greatest(0, ceil(extract(epoch from least(
           (select min(i.next_at) from history.imports i where i.status = 'open' and i.started_at is not null),
           (select min(d.due_at) from history.days d where d.status = 'queued' and d.import is null and d.claimed_until is null),
           (select min(t.due_at) from history.totals t where t.claimed_until is null)) - p_at)))::integer
$function$;
