-- ============================================================================
-- 0263 — the rest of the emails through the message outbox (SOLAR-645 step 5).
--
-- 0262 sends alert emails (lane urgent) from msg.outbox. This flips the bulk kinds still made
-- today, lane bulk, sent by notify-email's bulk slot with the same take / bind / done and the
-- same shared Resend pace:
--   welcome, need_a_hand, account_deleted  2 days
--   history                                 1 day (waits up to 2 h for day totals, then hourly)
--   report_week / _month / _year           3 days (a report waits up to ~65 h for history,
--                                                  then goes: the expiry must be past that)
--   share_removed, plant_off_login         2 days
--   feedback (to hello@)                   7 days
-- Not flipped: share_down / share_back (lane urgent, not alerts: a later step), and the dead
-- kinds nothing queues any more (old bill_*, free week, winback, unpaid_*, bill_mail_failed).
--
-- Hooks of the old path, ported:
--   guard, per kind, at send time (email_claim 0247): welcome dropped once a plant is linked;
--     need a hand dropped once a login is added, unless plants wait to be chosen; a report
--     asks billing.report_wanted (plan, chosen plant, still reached) instead of chosen and live;
--     history asks chosen and live; share_removed and plant_off_login skip chosen and live (the
--     share is gone, its claim released in the same step); plant removed and switches as before.
--     No user (account deleted) or no plant (welcome, feedback): those checks don't apply; the
--     address captured on the row is used.
--   take: need a hand with a login gets choose: true; a report loses freeWeekEnds; a kind with
--     a switch gets the unsubscribe token.
--   done: a hold (notify: a report waiting for history, history waiting for day totals or with
--     nothing to say yet) hands the row back hold_s on, the try given back; a hold past the
--     expiry drops the row with its reason.
--   settled (trigger): sent copies sent_at to the event row (link-sunsynk's need-a-hand count
--     reads it); feedback's message and screenshot are scrubbed from the event row once done
--     (0179); account_deleted's event row, address and all, is deleted once done (email_done).
--   email_history_open: a 60-days email still on its way, on either path (notify's report hold).
-- job-check: job_check_msg lists every channel and lane in msg.kinds routed to the outbox, so
-- email / bulk shows up from the flip.
--
-- Flip: rows queued before it finish on email_claim. Back:
-- update msg.kinds set route = 'old' where channel = 'email' and lane = 'bulk';   (new rows only)
-- ============================================================================

-- Kinds whose plant need not be chosen and read at send time (see the guard).
create function msg.email_any_plant(p_kind text)
returns boolean language sql immutable set search_path = '' as $$
  select p_kind in ('needs_relink', 'relinked', 'share_removed', 'plant_off_login') or p_kind like 'report\_%'
$$;

-- ---------------------------------------------------------------------------
-- 1. Guard: 0262's, with the per-kind rules of email_claim for the bulk kinds.
-- ---------------------------------------------------------------------------
create or replace function msg.email_guard(p_o msg.outbox)
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
           -- plan, chosen plant, still reached: asked again when sent (email_claim 0247)
           when q.kind like 'report\_%' and q.user_id is not null
                and not billing.report_wanted((select ba.id from billing.accounts ba where ba.user_id = q.user_id), q.plant_id)
             then 'report not wanted'
           -- reconnect: the login may hold other chosen plants; email_claim never asked (review).
           -- share_removed / plant_off_login: the plant has just left the account.
           when q.plant_id is not null and q.user_id is not null and not msg.email_any_plant(q.kind) and not exists (
                  select 1 from billing.seats se join billing.accounts ba on ba.id = se.account
                   where ba.user_id = q.user_id and se.plant = q.plant_id and se.closed_at is null)
             then 'plant not chosen'
           -- needs_relink is queued just before the login is marked broken (0261)
           when q.plant_id is not null and q.user_id is not null and not msg.email_any_plant(q.kind)
                and not private.plant_live(q.user_id, q.plant_id) then 'plant not live'
           when q.kind = 'welcome' and exists (select 1 from public.plant_users pu where pu.user_id = q.user_id)
             then 'plant linked'
           when q.kind = 'need_a_hand' and exists (select 1 from private.sunsynk_accounts a where a.user_id = q.user_id)
                and not private.pick_waiting(q.user_id)
             then 'login added'
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
-- 2. Take: 0262's, with email_claim's per-kind data and the unsubscribe token. A new column,
--    so dropped and made again.
-- ---------------------------------------------------------------------------
drop function public.msg_email_take(int, text);
create function public.msg_email_take(p_limit int default 50, p_lane text default 'urgent')
returns table (id bigint, claim uuid, tries int, batch_key text, event_id bigint, user_id uuid, to_email text,
               plant_id bigint, plant_name text, tz text, kind text, key text, data jsonb, unsub_token uuid)
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
end $$;

-- ---------------------------------------------------------------------------
-- 3. Done: 0262's, with hold_s: [{id, hold_s, error}] hands the row back hold_s seconds on,
--    the try given back, its batch key cleared; past the expiry the row is dropped with error.
-- ---------------------------------------------------------------------------
create or replace function public.msg_email_done(p_claim uuid, p_results jsonb)
returns void language sql security definer set search_path = '' as $$
  with res as (
    select (e->>'id')::bigint id, coalesce((e->>'code')::int, 0) code, (e->>'retry_s')::int retry_s, e->>'error' err,
           coalesce((e->>'untried')::boolean, false) untried, e->>'skip' skip,
           coalesce((e->>'keep')::boolean, false) keep, (e->>'hold_s')::int hold_s
      from jsonb_array_elements(coalesce(p_results, '[]')) e),
  plan as (
    select o.id, r.code, r.err, r.untried, r.skip, r.keep,
           not r.untried and r.hold_s is not null as held,
           now() + make_interval(secs => greatest(coalesce(r.hold_s, 0), 5)) as hold_at,
           r.code between 200 and 299 as ok,
           r.code in (400, 422) as refused,
           -- Retry-After 0 or past: still 5 s, or one pass would call Resend in a loop
           now() + make_interval(secs => greatest(coalesce(r.retry_s, least(60 * 2 ^ greatest(o.tries - 1, 0), 600)), 5)) as next_at,
           o.expires_at
      from res r
      join msg.outbox o on o.id = r.id and o.claim = p_claim and o.channel = 'email' and o.status = 'queued'),
  -- a hold is neither sent nor refused: the rules below read it as such
  p2 as (
    select p.*, p.held and p.hold_at >= p.expires_at as held_out,
           not p.held and p.ok as ok2, not p.held and p.refused as refused2,
           case when p.held then null else p.skip end as skip2
      from plan p)
  update msg.outbox o
     set status = case when p.untried then 'queued'
                       when p.held then case when p.held_out then 'dropped' else 'queued' end
                       when p.skip2 is not null then 'dropped'
                       when p.ok2 then 'sent'
                       when p.refused2 or p.next_at >= p.expires_at then 'failed'
                       else 'queued' end,
         drop_reason = case when p.held_out then left(coalesce(p.err, 'held'), 200)
                            when p.skip2 is not null and not p.untried then left(p.skip2, 200) else o.drop_reason end,
         not_before = case when p.held then p.hold_at
                           when p.untried or p.skip2 is not null or p.ok2 or p.refused2 then o.not_before else p.next_at end,
         -- a 429, a hold or a row never tried sent nothing: the try is given back
         tries = o.tries - case when (p.untried or p.held or p.code = 429) and o.tries > 0 then 1 else 0 end,
         n429 = o.n429 + (p.code = 429 and not p.untried and not p.held and p.skip2 is null)::int,
         last_429_at = case when p.code = 429 and not p.untried and not p.held and p.skip2 is null then now() else o.last_429_at end,
         last_error = case when p.untried then o.last_error
                           when p.held then left(coalesce(p.err, 'held'), 200)
                           when p.ok2 or p.skip2 is not null then null
                           when not p.refused2 and p.next_at >= p.expires_at then 'too old'
                           else left(coalesce(p.err, 'resend ' || p.code), 200) end,
         done_at = case when p.untried then null
                        when p.held then case when p.held_out then now() end
                        when p.skip2 is not null or p.ok2 or p.refused2 or p.next_at >= p.expires_at then now() end,
         batch_key = case when p.keep and not p.held and (p.untried or (p.skip2 is null and not p.ok2 and not p.refused2
                                                                       and p.next_at < p.expires_at))
                          then o.batch_key end,
         claim = null, claimed_until = null
    from p2 p
   where o.id = p.id
$$;

-- ---------------------------------------------------------------------------
-- 4. Settled: what the old path did once an email was done (email_done, 0179).
-- ---------------------------------------------------------------------------
create function msg.email_settled() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'sent' then
    update public.email_queue q set sent_at = now() where q.id = new.event_id;
  end if;
  if new.kind = 'feedback' then
    -- the message stays in private.feedback; its copy and the screenshot go (0179)
    update public.email_queue q set data = jsonb_build_object('id', q.data->'id') where q.id = new.event_id;
  elsif new.kind = 'account_deleted' then
    -- the person is gone: so is the address (email_done). Takes this outbox row with it.
    delete from public.email_queue q where q.id = new.event_id;
  end if;
  return null;
end $$;
create trigger msg_email_settled after update of status on msg.outbox
  for each row when (new.channel = 'email' and old.status = 'queued' and new.status <> 'queued')
  execute function msg.email_settled();

-- ---------------------------------------------------------------------------
-- 5. A plant's 60-days email still on its way, on either path (notify: a report waits for it).
-- ---------------------------------------------------------------------------
create function public.email_history_open(p_user uuid, p_plant bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.email_queue q
                  where q.user_id = p_user and q.plant_id = p_plant and q.kind = 'history'
                    and (q.status in ('queued', 'sending')
                         or (q.status = 'outbox' and exists (select 1 from msg.outbox o
                                                              where o.dedupe_key = q.id || ':email' and o.status = 'queued'))))
$$;

revoke all on function public.msg_email_take(int, text) from public, anon, authenticated;
revoke all on function public.msg_email_done(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.email_history_open(uuid, bigint) from public, anon, authenticated;
grant execute on function public.msg_email_take(int, text) to service_role;
grant execute on function public.msg_email_done(uuid, jsonb) to service_role;
grant execute on function public.email_history_open(uuid, bigint) to service_role;
revoke all on all functions in schema msg from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Flip: the bulk kinds go through the outbox from now on.
-- ---------------------------------------------------------------------------
insert into msg.kinds (kind, channel, route, lane, ttl)
values ('welcome', 'email', 'outbox', 'bulk', interval '2 days'),
       ('need_a_hand', 'email', 'outbox', 'bulk', interval '2 days'),
       ('account_deleted', 'email', 'outbox', 'bulk', interval '2 days'),
       ('history', 'email', 'outbox', 'bulk', interval '1 day'),
       ('report_week', 'email', 'outbox', 'bulk', interval '3 days'),
       ('report_month', 'email', 'outbox', 'bulk', interval '3 days'),
       ('report_year', 'email', 'outbox', 'bulk', interval '3 days'),
       ('share_removed', 'email', 'outbox', 'bulk', interval '2 days'),
       ('plant_off_login', 'email', 'outbox', 'bulk', interval '2 days'),
       ('feedback', 'email', 'outbox', 'bulk', interval '7 days');

notify pgrst, 'reload schema';
