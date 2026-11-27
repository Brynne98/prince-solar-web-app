CREATE OR REPLACE FUNCTION history.step_done(p_step text, p_id bigint, p_claim uuid, p_result text, p_note text DEFAULT NULL::text, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  d history.days;
  t history.totals;
  wait_s int;
  pace int;
  done_n int;
  total_n int;
  nxt timestamptz;
begin
  if p_result not in ('ok', 'failed', 'throttled', 'wait', 'refused') then
    raise exception 'history.step_done: unknown result %', p_result;
  end if;
  if p_step = 'totals' then
    select * into t from history.totals where plant = p_id for update;
    if not found then return jsonb_build_object('status', 'gone'); end if;
    if t.claim is distinct from p_claim then return jsonb_build_object('status', 'not_yours'); end if;
    if p_result = 'throttled' then perform history.back_off(t.lane, p_at); end if;
    if p_result = 'ok' or (p_result = 'failed' and t.tries + 1 >= 3) then
      perform history.lane_ok(t.lane) where p_result = 'ok';
      delete from history.totals where plant = p_id;
      return jsonb_build_object('status', case when p_result = 'ok' then 'done' else 'given_up' end);
    end if;
    update history.totals
       set claim = null, claimed_until = null, note = coalesce(p_note, note),
           tries = tries + case when p_result = 'failed' then 1 else 0 end,
           due_at = p_at + case p_result when 'failed' then interval '1 minute' when 'wait' then interval '5 minutes' else interval '0' end
     where plant = p_id;
    return jsonb_build_object('status', 'queued');
  end if;

  select * into d from history.days where id = p_id for update;
  if not found or d.status <> 'queued' then return jsonb_build_object('status', coalesce(d.status, 'gone')); end if;
  if d.claim is distinct from p_claim then return jsonb_build_object('status', 'not_yours'); end if;

  if p_result = 'throttled' then
    wait_s := history.back_off(d.lane, p_at);
    update history.days set claim = null, claimed_until = null, due_at = p_at + make_interval(secs => wait_s) where id = p_id;
  elsif p_result in ('wait', 'refused') then
    update history.days set claim = null, claimed_until = null, note = coalesce(p_note, note),
                            due_at = p_at + case when p_result = 'wait' then interval '5 minutes' else interval '1 minute' end
     where id = p_id;
  elsif p_result = 'failed' and d.tries + 1 < 3 then
    -- an extras day that lost only the grid endpoint: the next try asks that one alone (H12)
    update history.days set claim = null, claimed_until = null, tries = tries + 1, note = p_note, due_at = p_at + interval '1 minute',
                            grid_only = grid_only or coalesce(p_note like 'grid only:%', false)
     where id = p_id;
  else
    if p_result = 'ok' then perform history.lane_ok(d.lane); end if;
    update history.days set status = case when p_result = 'ok' then 'done' else 'given_up' end,
                            note = coalesce(p_note, note), claim = null, claimed_until = null, closed_at = p_at
     where id = p_id;
  end if;

  if d.import is not null then
    select count(*) filter (where x.status <> 'queued'), count(*) into done_n, total_n from history.days x where x.import = d.import;
    if done_n = total_n then
      update history.imports set status = 'done', finished_at = p_at, next_at = null where id = d.import and status = 'open';
    else
      -- spread evenly (H4): the last step starts no earlier than the pace after the first
      select coalesce(min(a.pace_s), 0) into pace from history.import_accounts a where a.import = d.import and a.left_at is null;
      select greatest(i.started_at + make_interval(secs => pace::numeric * done_n / greatest(total_n - 1, 1)),
                      (select min(x.due_at) from history.days x where x.import = d.import and x.status = 'queued'))
        into nxt from history.imports i where i.id = d.import;
      update history.imports set next_at = greatest(nxt, p_at) where id = d.import and status = 'open';
    end if;
  end if;
  return jsonb_build_object('status', (select x.status from history.days x where x.id = p_id),
                            'next_at', (select i.next_at from history.imports i where i.id = d.import));
end $function$;
