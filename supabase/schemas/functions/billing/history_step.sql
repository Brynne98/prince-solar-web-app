CREATE OR REPLACE FUNCTION billing.history_step(p_id bigint, p_day date, p_failed boolean DEFAULT false, p_throttled boolean DEFAULT false, p_at timestamp with time zone DEFAULT now(), p_claim uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  h billing.history_fetches;
  wait_s int;
  done int;
  nxt timestamptz;
begin
  select * into h from billing.history_fetches where id = p_id for update;
  if not found or h.status <> 'running' then
    return jsonb_build_object('go', false, 'status', h.status);
  end if;
  -- only the run that holds the claim moves or releases the fetch
  if h.claim is distinct from p_claim then
    return jsonb_build_object('go', false, 'status', 'not_yours');
  end if;
  if not billing.holds_plant(h.account, h.plant, p_at) then
    update billing.history_fetches set status = 'dropped', drop_reason = 'switched_out', finished_at = p_at, claimed_until = null
     where id = p_id;
    return jsonb_build_object('go', false, 'status', 'dropped');
  end if;
  -- not read now, or its route changed (the login broke or lost the plant): back to the
  -- queue with its days kept; history_take starts it again on a working route
  if not billing.reads_plant(h.account, h.plant, p_at) or billing.fetch_lane(h.account, h.plant) is distinct from h.lane then
    update billing.history_fetches set status = 'queued', lane = null, claimed_until = null, claim = null where id = p_id;
    return jsonb_build_object('go', false, 'status', 'requeued');
  end if;
  if p_throttled then
    insert into billing.history_lanes as hl (lane, backoff_s, backoff_until) values (h.lane, 60, p_at + interval '60 seconds')
    on conflict (lane) do update set backoff_s = least(greatest(hl.backoff_s * 2, 60), 3600),
                                     backoff_until = p_at + make_interval(secs => least(greatest(hl.backoff_s * 2, 60), 3600))
    returning backoff_s into wait_s;
    update billing.history_fetches set claimed_until = null, claim = null, next_step_at = p_at + make_interval(secs => wait_s) where id = p_id;
    return jsonb_build_object('go', false, 'backoff_s', wait_s);
  end if;
  if p_day is null or p_day is distinct from h.day_next then
    update billing.history_fetches set claimed_until = null, claim = null where id = p_id;
    return jsonb_build_object('go', false);
  end if;
  update billing.history_lanes set backoff_s = 0, backoff_until = null where lane = h.lane and backoff_s > 0;
  if p_failed and h.tries + 1 < 3 then
    update billing.history_fetches set tries = tries + 1, claimed_until = null, claim = null, next_step_at = p_at + interval '1 minute'
     where id = p_id;
    return jsonb_build_object('go', false, 'retry', h.tries + 1);
  end if;
  if p_day - 1 < h.day_floor then
    update billing.history_fetches set status = 'done', day_next = p_day - 1, tries = 0, finished_at = p_at, claimed_until = null
     where id = p_id;
    return jsonb_build_object('go', false, 'status', 'done');
  end if;
  -- spread evenly: the days_total starts sit on days_total - 1 gaps, so the last day starts no
  -- earlier than target_s after the first (the earliest finish meets the target)
  done := h.days_total - (p_day - h.day_floor);
  nxt := greatest(p_at, h.started_at + make_interval(secs => h.target_s::numeric * done / greatest(h.days_total - 1, 1)));
  update billing.history_fetches
     set day_next = p_day - 1, tries = 0, next_step_at = nxt,
         -- a slowed fetch lets its login go between days; one at once keeps its claim
         claimed_until = case when nxt <= p_at + interval '5 seconds' then nxt + interval '90 seconds' end,
         claim = case when nxt <= p_at + interval '5 seconds' then claim end
   where id = p_id;
  -- go only while this run keeps the claim: a slowed fetch is handed out again by history_take
  return jsonb_build_object('go', nxt <= p_at + interval '5 seconds', 'day', p_day - 1, 'next_step_at', nxt);
end $function$;
