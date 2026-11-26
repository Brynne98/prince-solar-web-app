CREATE OR REPLACE FUNCTION public.msg_email_take(p_limit integer DEFAULT 50, p_lane text DEFAULT 'urgent'::text)
 RETURNS TABLE(id bigint, claim uuid, tries integer, batch_key text, event_id bigint, user_id uuid, to_email text, plant_id bigint, plant_name text, tz text, kind text, key text, data jsonb, unsub_token uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_claim uuid := gen_random_uuid();
  r msg.outbox;
  v_why text;
  v_leased int := 0;
  v_moved int;
  k text;
begin
  -- rows already bound to a batch key: their call may have gone. Each passes the guard; what
  -- is left of a group is leased together and goes again under its key (notify).
  for k in
    select o.batch_key from msg.outbox o
     where o.channel = 'email' and o.lane = p_lane and o.status = 'queued' and o.batch_key is not null
       and o.not_before <= now() and (o.claimed_until is null or o.claimed_until < now())
     group by o.batch_key order by min(o.not_before), o.batch_key
  loop
    exit when v_leased >= p_limit;
    -- a worker taking the same group at once waits here, then finds it leased
    for r in
      select o.* from msg.outbox o
       where o.batch_key = k and o.status = 'queued' and o.not_before <= now()
         and (o.claimed_until is null or o.claimed_until < now())
       order by o.id
       for update
    loop
      v_why := msg.email_guard(r);
      if v_why = 'wait' then continue; end if;
      if v_why is not null then
        update msg.outbox o set status = 'dropped', drop_reason = v_why, claim = null, claimed_until = null, done_at = now()
         where o.id = r.id;
        continue;
      end if;
      update msg.outbox o set claim = v_claim, claimed_until = now() + interval '2 minutes', tries = o.tries + 1
       where o.id = r.id;
      v_leased := v_leased + 1;
    end loop;
  end loop;

  -- dropped rows don't count: take again until p_limit are leased or nothing moves (review)
  loop
    v_moved := 0;
    for r in
      select o.* from msg.outbox o
       where o.channel = 'email' and o.lane = p_lane and o.status = 'queued' and o.not_before <= now()
         and (o.claimed_until is null or o.claimed_until < now())  -- a lease that ran out: the reply was lost
         and o.batch_key is null
         and msg.email_guard(o) is distinct from 'wait'            -- waiting rows never fill the take
       order by o.not_before, o.id
       limit greatest(p_limit - v_leased, 0)
       for update skip locked
    loop
      v_why := msg.email_guard(r);
      if v_why = 'wait' then continue; end if;                     -- its "down" moved on since the select
      v_moved := v_moved + 1;
      if v_why is not null then
        update msg.outbox o set status = 'dropped', drop_reason = v_why, claim = null, claimed_until = null, done_at = now()
         where o.id = r.id;
        continue;
      end if;
      update msg.outbox o set claim = v_claim, claimed_until = now() + interval '2 minutes', tries = o.tries + 1
       where o.id = r.id;
      v_leased := v_leased + 1;
    end loop;
    exit when v_moved = 0 or v_leased >= p_limit;
  end loop;

  -- the old email_claim's fields, so notify builds the same email
  return query
  select o.id, v_claim, o.tries, o.batch_key, q.id, q.user_id,
         coalesce(q.to_email, u.email::text, o.to_email), q.plant_id,
         coalesce(pu.plant_name, (select pu2.plant_name from public.plant_users pu2
                                   where pu2.user_id = q.user_id order by pu2.linked_at limit 1)),
         case when q.plant_id is not null then public.plant_tz(q.plant_id) else 'Africa/Johannesburg' end,
         q.kind, q.key,
         -- email_claim's per-kind data (0247): need a hand with a login names choosing plants;
         -- a report has no free-week wording since billing went live
         case when q.kind = 'need_a_hand' and exists (select 1 from private.sunsynk_accounts a where a.user_id = q.user_id)
                then coalesce(q.data, '{}'::jsonb) || '{"choose": true}'::jsonb
              when q.kind like 'report\_%' then q.data - 'freeWeekEnds'
              else q.data end,
         -- a kind with a switch gets the user's unsubscribe token, as email_claim
         case when q.user_id is not null and private.email_switch_of(q.kind, q.data) is not null
              then public.email_unsub_token(q.user_id) end
    from msg.outbox o
    join public.email_queue q on q.id = o.event_id
    left join auth.users u on u.id = q.user_id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
   where o.claim = v_claim and o.status = 'queued'
   order by o.batch_key nulls last, o.id;
end $function$;
