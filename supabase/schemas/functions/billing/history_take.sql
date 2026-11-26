CREATE OR REPLACE FUNCTION billing.history_take(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  q record;
  tz text;
  today date;
  out jsonb;
begin
  if not billing.is_live() then return '[]'::jsonb; end if;
  if not pg_try_advisory_xact_lock(hashtext('billing.history_take')) then return '[]'::jsonb; end if;
  update billing.history_fetches h set status = 'dropped', drop_reason = 'switched_out', finished_at = p_at, claimed_until = null, claim = null
   where h.status in ('queued', 'running') and h.requested_at <= p_at and not billing.holds_plant(h.account, h.plant, p_at);
  -- a running fetch whose route changed (its login broke or no longer sees the plant, a claim
  -- went) or that is not read now (over the places): back to the queue, its days kept
  update billing.history_fetches h set status = 'queued', lane = null, claimed_until = null, claim = null
   where h.status = 'running' and h.requested_at <= p_at
     and (billing.fetch_lane(h.account, h.plant) is distinct from h.lane or not billing.reads_plant(h.account, h.plant, p_at));

  -- a login starts its next request when nothing on it has a step due or under way (a slowed
  -- fetch waiting for its next day does not hold it); on a shared login the account whose last
  -- fetch there started longest ago (or never) goes first
  for q in
    select h.id, h.plant, x.lane from billing.history_fetches h
     cross join lateral (select billing.fetch_lane(h.account, h.plant) lane) x
     where h.status = 'queued' and h.requested_at <= p_at and x.lane is not null
       and billing.reads_plant(h.account, h.plant, p_at)
     order by x.lane,
              (select max(o.started_at) from billing.history_fetches o where o.lane = x.lane and o.account = h.account) nulls first,
              h.requested_at, h.id
  loop
    continue when exists (select 1 from billing.history_fetches r where r.lane = q.lane and r.status = 'running'
                             and (r.next_step_at <= p_at or r.claimed_until > p_at))
               or exists (select 1 from billing.history_lanes hl where hl.lane = q.lane and hl.backoff_until > p_at);
    tz := plants.tz(q.plant);
    today := (p_at at time zone tz)::date;
    -- a fetch put back keeps its walk: started_at, floor and the next day stay
    update billing.history_fetches
       set status = 'running', lane = q.lane, started_at = coalesce(started_at, p_at), next_step_at = p_at,
           day_floor = coalesce(day_floor, today - 60), day_next = coalesce(day_next, today - 1),
           days_total = coalesce(days_total, 60), tries = 0
     where id = q.id;
  end loop;

  -- one step per login at a time: its earliest due fetch
  with due as (
    select distinct on (h.lane) h.id from billing.history_fetches h
     where h.status = 'running' and h.next_step_at <= p_at and (h.claimed_until is null or h.claimed_until <= p_at)
       and not exists (select 1 from billing.history_fetches o where o.lane = h.lane and o.status = 'running'
                          and o.id <> h.id and o.claimed_until > p_at)
       and not exists (select 1 from billing.history_lanes hl where hl.lane = h.lane and hl.backoff_until > p_at)
       and billing.reads_plant(h.account, h.plant, p_at)
       and exists (select 1 from plants.logins sa where sa.id = h.lane and sa.status = 'ok')
     order by h.lane, h.next_step_at, h.id),
  w as (
    update billing.history_fetches h
       set claimed_until = p_at + interval '90 seconds', claim = gen_random_uuid(),
           version = (select bp.version from plants.plants bp where bp.id = h.plant)
     where h.id in (select id from due)
    returning h.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', w.id, 'claim', w.claim, 'plant', w.plant, 'account', w.account, 'day', w.day_next, 'floor', w.day_floor,
           'target_s', w.target_s, 'version', w.version,
           'timezone', plants.tz(w.plant), 'vendor_plant_id', (select p.vendor_id from plants.plants p where p.id = w.plant),
           'login', jsonb_build_object('id', sa.id, 'user_id', sa.user_id, 'username', sa.username, 'brand', sa.brand,
                                       'access_token', sa.access_token, 'access_expires_at', sa.access_expires_at))
           order by w.id), '[]'::jsonb)
    into out
    from w join plants.logins sa on sa.id = w.lane
    left join public.plant_config c on c.plant_id = w.plant;
  perform billing.heartbeat('history', p_at, jsonb_build_object('handed_out', jsonb_array_length(out)));
  return out;
end $function$;
