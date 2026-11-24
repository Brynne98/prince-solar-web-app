-- ============================================================================
-- 0262 — alert emails through the message outbox (SOLAR-645 step 4).
--
-- 0261 built the route for email: an alert event routed to the outbox gets status 'outbox'
-- (email_claim never sees it) and one msg.outbox row '<event id>:email', lane urgent,
-- not_before = due_at, 1 h expiry. This adds its sender (notify-email, urgent slot):
--   take  rows due, not leased (or the lease ran out: a lost reply), pass the guard, are
--         leased 2 minutes under one claim token, tries + 1, and come back with the event
--         row's fields so the email is built by the same code as the old path.
--         Guard, at send time: expired; event gone; battery-hot and bank-drift "back" (no
--         email, as notify's build); switch off (email_wanted, not for kinds with no switch);
--         plant removed (not for needs_relink, as email_claim); plant not chosen and plant
--         not live (neither for needs_relink / relinked: see 0261); no address. A "back" waits
--         while its "down" email is queued or leased, on either path; it is dropped only
--         if its "down" was dropped, skipped or failed.
--   done  per row, only under the claim that leased it: 2xx sent; 400, 422 failed (Resend
--         refused the email); 429 again after Retry-After, the try given back, counted;
--         anything else (0 = no answer, 5xx, 401, 403, 404, 409) again after Retry-After or
--         60 s doubling to 10 min; past the expiry it fails 'too old'. 'untried' hands a row
--         back at once, try given back; 'skip' drops it with that reason.
--   bind  rows going out together in one Resend batch call (up to 100) get its key saved
--         BEFORE the call (msg_email_bind), which also renews their lease. A saved row only
--         ever goes again under that key: after a lost reply, a 5xx or a dead worker, the
--         rows still due come back under it (each through the guard and its own expiry) and
--         go in one call under it. If the first call reached Resend, Resend answers from it
--         (the same rows) or with 409 invalid_idempotent_request (fewer rows), both counted
--         as sent; if it didn't, the call is a first send. Nothing goes twice. A refusal
--         (400, 422) means nothing went under the key: it is cleared, each row goes alone.
-- A row alone goes in its own call under ms-<outbox id>, no key saved. A lease that runs out
-- after the expiry drops the row 'too old' even if the lost send went; accepted.
-- Batching (2026-11-24, Brynne agreed): one call per email capped alerts at ~60 a minute; a
-- load-shedding wave queues hundreds at once.
--
-- email_claim learns the outbox for a "down": its "back" on the old path waits while the
-- outbox email is queued and is skipped unless it was sent.
--
-- Flip: email for every alert kind. Rows queued before it finish on email_claim. Back:
-- update msg.kinds set route = 'old' where channel = 'email';   (new rows only)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lease token, 429 count and batch key on the outbox row (email; push keeps its per device)
-- ---------------------------------------------------------------------------
alter table msg.outbox add column claim uuid,
                       add column n429 int not null default 0,
                       add column last_429_at timestamptz,
                       add column batch_key text;            -- Resend batch key, saved before the call
create index msg_outbox_429_idx on msg.outbox (last_429_at) where n429 > 0;
create index msg_outbox_batch_idx on msg.outbox (batch_key) where batch_key is not null;

-- ---------------------------------------------------------------------------
-- 2. A "back"'s "down" email, on either path: 'wait', 'ok', 'dropped'.
-- ---------------------------------------------------------------------------
create function msg.email_down_state(p_user uuid, p_pair_key text)
returns text language sql stable security definer set search_path = '' as $$
  select case
           when d.id is null then 'dropped'
           when d.status = 'outbox' then
             case (select o.status from msg.outbox o where o.dedupe_key = d.id || ':email')
               when 'queued' then 'wait' when 'sent' then 'ok' else 'dropped' end
           when d.status in ('queued', 'sending') then 'wait'
           when d.status = 'sent' then 'ok'
           else 'dropped'
         end
    from (select 1) one
    left join public.email_queue d on d.user_id is not distinct from p_user and d.key = p_pair_key
$$;

-- Why an email must not go now: a drop reason, 'wait', or null (send it).
create function msg.email_guard(p_o msg.outbox)
returns text language sql stable security definer set search_path = '' as $$
  select case
           when p_o.expires_at <= now() then 'too old'
           when q.id is null then 'event gone'
           -- kept in the app's bell, no email (notify build, SOLAR-415)
           when q.kind in ('batt_hot_back', 'bank_drift_back') then 'no email for this kind'
           when q.user_id is not null and private.email_switch_of(q.kind, q.data) is not null
                and not public.email_wanted(q.user_id, private.email_switch_of(q.kind, q.data)) then 'switched off'
           when q.plant_id is not null and q.user_id is not null and q.kind <> 'needs_relink'
                and not exists (select 1 from public.plant_users pu where pu.user_id = q.user_id and pu.plant_id = q.plant_id)
             then 'plant removed'
           -- reconnect: the login may hold other chosen plants; email_claim never asked (review)
           when q.plant_id is not null and q.user_id is not null and q.kind not in ('needs_relink', 'relinked') and not exists (
                  select 1 from billing.seats se join billing.accounts ba on ba.id = se.account
                   where ba.user_id = q.user_id and se.plant = q.plant_id and se.closed_at is null)
             then 'plant not chosen'
           -- needs_relink is queued just before the login is marked broken (0261)
           when q.plant_id is not null and q.user_id is not null and q.kind not in ('needs_relink', 'relinked')
                and not private.plant_live(q.user_id, q.plant_id) then 'plant not live'
           when coalesce(q.to_email, (select u.email::text from auth.users u where u.id = q.user_id), p_o.to_email) is null
             then 'no address'
           when q.pair_key is not null then
             case msg.email_down_state(q.user_id, q.pair_key)
               when 'wait' then 'wait' when 'dropped' then 'down not sent' end
         end
    from (select 1) one
    left join public.email_queue q on q.id = p_o.event_id
$$;

-- ---------------------------------------------------------------------------
-- 3. Take
-- ---------------------------------------------------------------------------
create function public.msg_email_take(p_limit int default 50, p_lane text default 'urgent')
returns table (id bigint, claim uuid, tries int, batch_key text, event_id bigint, user_id uuid, to_email text,
               plant_id bigint, plant_name text, tz text, kind text, key text, data jsonb)
language plpgsql security definer set search_path = '' as $$
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
         q.kind, q.key, q.data
    from msg.outbox o
    join public.email_queue q on q.id = o.event_id
    left join auth.users u on u.id = q.user_id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
   where o.claim = v_claim and o.status = 'queued'
   order by o.batch_key nulls last, o.id;
end $$;

-- ---------------------------------------------------------------------------
-- 3b. Bind: the rows of one Resend batch call get its key before the call, and their lease is
--     renewed (the build and the pace may have used it). All or none: it raises, binding
--     nothing, when any row is no longer leased under this claim or is already bound.
-- ---------------------------------------------------------------------------
create function public.msg_email_bind(p_claim uuid, p_key text, p_ids bigint[])
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  update msg.outbox o set batch_key = p_key, claimed_until = now() + interval '2 minutes'
   where o.id = any (p_ids) and o.claim = p_claim and o.status = 'queued' and o.batch_key is null
     and o.channel = 'email';
  get diagnostics v_n = row_count;
  if v_n <> cardinality(p_ids) then
    raise exception 'msg_email_bind: % of % rows', v_n, cardinality(p_ids);
  end if;
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Done: [{id, code?, retry_s?, error?, untried?, skip?, keep?}]. code is Resend's HTTP
--    status, 0 = no answer. Only the claim that leased a row can close it. keep: the row's
--    batch call may have gone (no answer, 5xx, a 409 still in progress, or any answer short
--    of sent or refused to rows retaken under their key): the key stays while the row stays
--    queued. Otherwise it is cleared.
-- ---------------------------------------------------------------------------
create function public.msg_email_done(p_claim uuid, p_results jsonb)
returns void language sql security definer set search_path = '' as $$
  with res as (
    select (e->>'id')::bigint id, coalesce((e->>'code')::int, 0) code, (e->>'retry_s')::int retry_s, e->>'error' err,
           coalesce((e->>'untried')::boolean, false) untried, e->>'skip' skip,
           coalesce((e->>'keep')::boolean, false) keep
      from jsonb_array_elements(coalesce(p_results, '[]')) e),
  plan as (
    select o.id, r.code, r.err, r.untried, r.skip, r.keep,
           r.code between 200 and 299 as ok,
           r.code in (400, 422) as refused,
           -- Retry-After 0 or past: still 5 s, or one pass would call Resend in a loop
           now() + make_interval(secs => greatest(coalesce(r.retry_s, least(60 * 2 ^ greatest(o.tries - 1, 0), 600)), 5)) as next_at,
           o.expires_at
      from res r
      join msg.outbox o on o.id = r.id and o.claim = p_claim and o.channel = 'email' and o.status = 'queued')
  update msg.outbox o
     set status = case when p.untried then 'queued'
                       when p.skip is not null then 'dropped'
                       when p.ok then 'sent'
                       when p.refused or p.next_at >= p.expires_at then 'failed'
                       else 'queued' end,
         drop_reason = case when p.skip is not null and not p.untried then left(p.skip, 200) else o.drop_reason end,
         not_before = case when p.untried or p.skip is not null or p.ok or p.refused then o.not_before else p.next_at end,
         -- a 429 or a row never tried sent nothing: the try is given back
         tries = o.tries - case when (p.untried or p.code = 429) and o.tries > 0 then 1 else 0 end,
         n429 = o.n429 + (p.code = 429 and not p.untried and p.skip is null)::int,
         last_429_at = case when p.code = 429 and not p.untried and p.skip is null then now() else o.last_429_at end,
         last_error = case when p.untried then o.last_error
                           when p.ok or p.skip is not null then null
                           when not p.refused and p.next_at >= p.expires_at then 'too old'
                           else left(coalesce(p.err, 'resend ' || p.code), 200) end,
         done_at = case when p.untried then null
                        when p.skip is not null or p.ok or p.refused or p.next_at >= p.expires_at then now() end,
         batch_key = case when p.keep and (p.untried or (p.skip is null and not p.ok and not p.refused
                                                          and p.next_at < p.expires_at))
                          then o.batch_key end,
         claim = null, claimed_until = null
    from plan p
   where o.id = p.id
$$;

revoke all on function public.msg_email_take(int, text) from public, anon, authenticated;
revoke all on function public.msg_email_done(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.msg_email_bind(uuid, text, bigint[]) from public, anon, authenticated;
grant execute on function public.msg_email_bind(uuid, text, bigint[]) to service_role;
grant execute on function public.msg_email_take(int, text) to service_role;
grant execute on function public.msg_email_done(uuid, jsonb) to service_role;
revoke all on all functions in schema msg from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. email_claim: a "down" may be on the outbox. Its "back" waits while the outbox email is
--    queued or leased, and is skipped unless it was sent. Body 0247 (0257 patch kept).
-- ---------------------------------------------------------------------------
do $$
declare
  d text := pg_get_functiondef('public.email_claim(int, boolean, text)'::regprocedure);
  skip_old text := $o$                     and d.status in ('sent', 'sending', 'queued'))$o$;
  wait_old text := $o$                                and (d.status = 'sending' or (d.status = 'queued' and d.due_at > now())))$o$;
begin
  if position(skip_old in d) = 0 or position(wait_old in d) = 0 then
    raise exception 'email_claim changed since 0257: edit it by hand';
  end if;
  d := replace(d, skip_old, $n$                     and (d.status in ('sent', 'sending', 'queued')
                          or (d.status = 'outbox' and exists (select 1 from msg.outbox o                -- 0262
                               where o.dedupe_key = d.id || ':email' and o.status = 'sent'))))$n$);
  d := replace(d, wait_old, $n$                                and (d.status = 'sending' or (d.status = 'queued' and d.due_at > now())
                                     or (d.status = 'outbox' and exists (select 1 from msg.outbox o     -- 0262
                                          where o.dedupe_key = d.id || ':email' and o.status = 'queued'))))$n$);
  execute d;
end $$;

-- ---------------------------------------------------------------------------
-- 6. job-check: the email lane's oldest counts rows whose lease ran out and leaves out a
--    "back" waiting on its "down"; 429s are counted for email from the outbox row.
-- ---------------------------------------------------------------------------
create or replace function public.job_check_msg()
returns jsonb language sql stable security definer set search_path = '' as $$
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
$$;
revoke all on function public.job_check_msg() from public, anon, authenticated;
grant execute on function public.job_check_msg() to service_role;

-- ---------------------------------------------------------------------------
-- 7. Flip: alert emails go through the outbox from now on (urgent lane).
-- ---------------------------------------------------------------------------
update msg.kinds set route = 'outbox' where channel = 'email';

notify pgrst, 'reload schema';
