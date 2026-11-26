CREATE OR REPLACE FUNCTION public.email_history_open(p_user uuid, p_plant bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from public.email_queue q
                  where q.user_id = p_user and q.plant_id = p_plant and q.kind = 'history'
                    and q.status = 'outbox'                                              -- 0267
                    and exists (select 1 from msg.outbox o where o.dedupe_key = q.id || ':email' and o.status = 'queued'))
$function$;
