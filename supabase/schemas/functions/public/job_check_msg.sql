CREATE OR REPLACE FUNCTION public.job_check_msg()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'channel', l.channel, 'lane', l.lane,
           'queued', (select count(*) from msg.outbox o where o.channel = l.channel and o.lane = l.lane and o.status = 'queued'),
           -- oldest due and not handled: a row not leased (or its lease ran out) and not waiting
           -- on its "down", or a device send due
           'oldest', least(
              (select min(o.not_before) from msg.outbox o
                where o.channel = l.channel and o.lane = l.lane and o.status = 'queued' and o.not_before <= now()
                  and (o.claimed_until is null or (l.channel = 'email' and o.claimed_until < now()))
                  and case l.channel when 'push' then msg.push_guard(o) else msg.email_guard(o) end is distinct from 'wait'),
              (select min(s.not_before) from msg.push_sends s join msg.outbox o on o.id = s.outbox_id
                where l.channel = 'push' and o.lane = l.lane and s.status in ('queued', 'sending') and s.not_before <= now()
                  and (s.status = 'queued' or s.claimed_until < now()))),
           'expired', (select count(*) from msg.outbox o where o.channel = l.channel and o.lane = l.lane
                         and o.done_at > now() - interval '1 hour'
                         and (o.drop_reason = 'too old' or o.last_error = 'too old')),
           'n429', (select coalesce(sum(s.n429), 0) from msg.push_sends s join msg.outbox o on o.id = s.outbox_id
                     where l.channel = 'push' and o.lane = l.lane and s.n429 > 0 and s.updated_at > now() - interval '1 hour')
                 + (select coalesce(sum(o.n429), 0) from msg.outbox o
                     where l.channel = 'email' and o.channel = 'email' and o.lane = l.lane and o.n429 > 0
                       and o.last_429_at > now() - interval '1 hour'))
         order by l.channel, l.lane), '[]'::jsonb)
    from (select distinct k.channel, k.lane from msg.kinds k where k.route = 'outbox') l
$function$;
