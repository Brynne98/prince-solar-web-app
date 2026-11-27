CREATE OR REPLACE FUNCTION history.stuck(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('waiting', count(*), 'oldest_due', min(d.due_at))
    from history.days d
   where d.status = 'queued' and d.due_at < p_at - interval '30 minutes'
     and (d.claimed_until is null or d.claimed_until <= p_at)
     and d.plant in (select r.plant from billing.reading_routes(p_at) r)
$function$;
