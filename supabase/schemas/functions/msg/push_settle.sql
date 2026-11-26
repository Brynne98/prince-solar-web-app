CREATE OR REPLACE FUNCTION msg.push_settle(p_ids bigint[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update msg.outbox o
     set status = case when exists (select 1 from msg.push_sends s where s.outbox_id = o.id and s.status = 'sent')
                       then 'sent' else 'failed' end,
         last_error = case when exists (select 1 from msg.push_sends s where s.outbox_id = o.id and s.status = 'sent') then null
                           else coalesce((select s.last_error from msg.push_sends s where s.outbox_id = o.id
                                           order by s.last_error = 'too old' desc, s.updated_at desc, s.id desc limit 1),
                                         'no device') end,
         claimed_until = null, done_at = now()
   where o.id = any (p_ids) and o.channel = 'push' and o.status = 'queued' and o.claimed_until is not null
     and not exists (select 1 from msg.push_sends s where s.outbox_id = o.id and s.status in ('queued', 'sending'))
$function$;
