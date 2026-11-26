CREATE OR REPLACE FUNCTION public.job_check_push()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select jsonb_build_object('waiting', count(*), 'oldest', min(created_at))
    from public.email_queue
   where pushed_at is null and user_id is not null and private.is_alert(kind)
     and created_at > now() - interval '1 hour' and created_at <= now() - interval '5 minutes'
$function$;
