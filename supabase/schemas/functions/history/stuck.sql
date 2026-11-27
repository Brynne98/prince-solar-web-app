CREATE OR REPLACE FUNCTION history.stuck(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with due as (
    select d.plant from history.days d
      left join history.imports i on i.id = d.import
     where d.status = 'queued' and (d.claimed_until is null or d.claimed_until <= p_at)
       and coalesce(i.next_at, d.due_at) < p_at - interval '30 minutes' and d.due_at < p_at - interval '30 minutes'
       and d.plant in (select r.plant from billing.reading_routes(p_at) r))
  select jsonb_build_object(
    'waiting', (select count(*) from due),
    'last_step_at', (select max(d.closed_at) from history.days d),
    'stuck', exists (select 1 from due)
             and coalesce((select max(d.closed_at) from history.days d), '-infinity') < p_at - interval '30 minutes')
$function$;
