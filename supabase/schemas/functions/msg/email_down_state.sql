CREATE OR REPLACE FUNCTION msg.email_down_state(p_user uuid, p_pair_key text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
           when d.id is null then 'dropped'
           when d.status = 'outbox' then
             case (select o.status from msg.outbox o where o.dedupe_key = d.id || ':email')
               when 'queued' then 'wait' when 'sent' then 'ok' else 'dropped' end
           when d.status = 'sent' then 'ok'          -- sent on the old path, before 0265
           else 'dropped'                            -- 0267: no old-queue wait
         end
    from (select 1) one
    left join public.email_queue d on d.user_id is not distinct from p_user and d.key = p_pair_key
$function$;
