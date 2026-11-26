CREATE OR REPLACE FUNCTION public.msg_push_take(p_limit integer DEFAULT 200)
 RETURNS TABLE(id bigint, claim uuid, event_id bigint, kind text, plant_id bigint, data jsonb, created numeric, tz text, plant_name text, plants integer, endpoint text, p256dh text, auth text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_claim uuid := gen_random_uuid();
  r msg.outbox;
  v_why text;
  v_n int;
begin
  -- 1. a lease that ran out: the reply was lost or the worker died. It goes again.
  update msg.push_sends s set status = 'queued', claim = null, claimed_until = null, updated_at = now()
   where s.status = 'sending' and s.claimed_until < now();

  -- 2. sends whose device was removed, then sends past their event's expiry
  update msg.push_sends s set status = 'gone', last_error = 'device removed', updated_at = now()
   where s.status = 'queued' and s.sub_id is null;
  update msg.push_sends s set status = 'failed', last_error = 'too old', updated_at = now()
    from msg.outbox o
   where o.id = s.outbox_id and s.status = 'queued' and o.expires_at <= now();

  -- 3. settle rows with nothing left open
  perform msg.push_settle(array(
    select o.id from msg.outbox o
     where o.channel = 'push' and o.status = 'queued' and o.claimed_until is not null
       and not exists (select 1 from msg.push_sends s where s.outbox_id = o.id and s.status in ('queued', 'sending'))));

  -- 4. new rows: guard, then one send per device
  for r in
    select o.* from msg.outbox o
     where o.channel = 'push' and o.status = 'queued' and o.claimed_until is null and o.not_before <= now()
       and msg.push_guard(o) is distinct from 'wait'           -- waiting rows never fill the take
     order by o.lane = 'urgent' desc, o.not_before, o.id
     limit p_limit
     for update skip locked
  loop
    v_why := msg.push_guard(r);
    if v_why = 'wait' then continue; end if;                  -- its "down" moved on since the select
    if v_why is not null then
      update msg.outbox o set status = 'dropped', drop_reason = v_why, done_at = now() where o.id = r.id;
      continue;
    end if;
    insert into msg.push_sends (outbox_id, sub_id)
    select r.id, ps.id
      from public.push_subs ps
      join public.email_queue q on q.id = r.event_id
     where ps.user_id = r.user_id and ps.platform = 'web'
       -- a "back" goes only to the devices that took its "down" through the outbox
       and (q.pair_key is null
            or not exists (select 1 from public.email_queue d
                            where d.user_id = q.user_id and d.key = q.pair_key and d.push_skip = 'outbox')
            or ps.id in (select s.sub_id from public.email_queue d
                           join msg.outbox od on od.dedupe_key = d.id || ':push'
                           join msg.push_sends s on s.outbox_id = od.id and s.status = 'sent'
                          where d.user_id = q.user_id and d.key = q.pair_key));
    get diagnostics v_n = row_count;
    if v_n = 0 then
      update msg.outbox o set status = 'dropped', drop_reason = 'no device', done_at = now() where o.id = r.id;
    else
      update msg.outbox o set claimed_until = o.expires_at, tries = o.tries + 1 where o.id = r.id;
    end if;
  end loop;

  -- 5. lease due sends under one claim
  return query
  with leased as (
    update msg.push_sends s
       set status = 'sending', claim = v_claim, claimed_until = now() + interval '2 minutes',
           tries = s.tries + 1, updated_at = now()
     where s.id in (select s2.id from msg.push_sends s2
                      join msg.outbox o2 on o2.id = s2.outbox_id
                     where s2.status = 'queued' and s2.not_before <= now() and o2.expires_at > now()
                       and s2.sub_id is not null
                     order by o2.lane = 'urgent' desc, s2.not_before, s2.id
                     limit p_limit
                     for update of s2 skip locked)
    returning s.id, s.outbox_id, s.sub_id)
  select l.id, v_claim, q.id, q.kind, q.plant_id,
         q.data, extract(epoch from q.created_at), public.plant_tz(q.plant_id), pu.plant_name,     -- 0264
         (select count(*)::int from public.plant_users n where n.user_id = q.user_id),
         ps.endpoint, ps.p256dh, ps.auth
    from leased l
    join msg.outbox o on o.id = l.outbox_id
    join public.email_queue q on q.id = o.event_id
    join public.push_subs ps on ps.id = l.sub_id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
   order by l.id;
end $function$;
