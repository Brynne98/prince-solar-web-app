CREATE OR REPLACE FUNCTION msg.push_down_state(p_user uuid, p_pair_key text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
           when d.id is null then 'dropped'
           when d.push_skip = 'outbox' then
             case (select o.status from msg.outbox o where o.dedupe_key = d.id || ':push')
               when 'queued' then 'wait' when 'sent' then 'ok' else 'dropped' end
           -- pushed on the old path, before 0261; 0267: a row never handled no longer waits
           when d.pushed_at is not null and d.push_skip is null then 'ok'
           else 'dropped'
         end
    from (select 1) one
    left join public.email_queue d on d.user_id = p_user and d.key = p_pair_key
$function$;
