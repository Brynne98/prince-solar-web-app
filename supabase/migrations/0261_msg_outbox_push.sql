-- ============================================================================
-- 0261 — message outbox, pop-ups first (SOLAR-645 step 3).
--
-- email_queue stays the event log (the alert list reads it). Each kind and channel now
-- has a route: 'old' (email_claim / push_claim, as before) or 'outbox'. The route is read
-- once, when the event row is inserted, and never decided again:
--   push, outbox:  the row gets pushed_at = now(), push_skip = 'outbox' (push_claim
--                  never sees it) and one msg.outbox row '<event id>:push'.
--   email, outbox: the row gets status 'outbox' (email_claim never sees it) and one
--                  msg.outbox row '<event id>:email'. No sender yet: step 4 adds it.
-- Only rows inserted as 'queued' get outbox rows. Reconnect's 'skipped' copies for
-- plants 2..N get none; their pop-up is marked 'one per login', as push_claim did.
--
-- Pop-ups through the outbox (notify-push, msg_push_take / msg_push_done):
--   take  1. sends whose lease ran out (lost reply) go back to queued;
--         2. queued sends past the event's expiry fail 'too old';
--         3. outbox rows with no send left open settle: 'sent' if any device took it,
--            else 'failed';
--         4. new outbox rows pass the guard: expired, plant removed, plant not chosen,
--            plant not live (not for reconnect / reconnected), switch off. A "back" waits while its "down" is queued on
--            either path; it is dropped only if its "down" was dropped or failed.
--            Passed: one send per device (a "back" only to devices that took its
--            "down"), and the row is leased until it expires;
--         5. leases due sends under one claim token and returns them with their words.
--   done  per device, only under the claim token that leased it: 2xx sent; 404, 410
--         device removed; 429, 5xx, no answer (0) tried again inside the expiry
--         (Retry-After, or 30 s doubling to 10 min); anything else failed.
-- A reply lost after a send was made: the lease runs out and it goes again. Accepted.
--
-- Flip: push for every alert kind. Rows queued before it finish on push_claim. Back:
-- update msg.kinds set route = 'old' where channel = 'push' (new rows only).
-- push_claim learns the outbox for a "down" so a pair split across the flip still pairs.
-- ============================================================================

create schema if not exists msg;
revoke all on schema msg from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
create table msg.kinds (
  kind    text not null,
  channel text not null check (channel in ('email', 'push')),
  route   text not null default 'old' check (route in ('old', 'outbox')),
  lane    text not null default 'urgent' check (lane in ('urgent', 'bulk')),
  ttl     interval not null default interval '1 hour',
  primary key (kind, channel)
);
alter table msg.kinds enable row level security;

insert into msg.kinds (kind, channel)
select k, c
  from unnest(array['grid_down', 'grid_back', 'batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back',
                    'string_dead', 'string_back', 'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back',
                    'needs_relink', 'relinked']) k
 cross join unnest(array['email', 'push']) c;

create table msg.outbox (
  id            bigint generated always as identity primary key,
  event_id      bigint not null references public.email_queue (id) on delete cascade,
  channel       text not null check (channel in ('email', 'push')),
  lane          text not null check (lane in ('urgent', 'bulk')),
  kind          text not null,
  user_id       uuid,
  to_email      text,                       -- captured at insert, for kinds whose user is gone at send
  dedupe_key    text not null unique,       -- '<event id>:<channel>'
  not_before    timestamptz not null default now(),
  expires_at    timestamptz not null,
  status        text not null default 'queued' check (status in ('queued', 'sent', 'dropped', 'failed')),
  claimed_until timestamptz,                -- push: set when the device sends are made, to expires_at
  tries         int not null default 0,
  drop_reason   text,
  last_error    text,
  created_at    timestamptz not null default now(),
  done_at       timestamptz
);
create index msg_outbox_due_idx on msg.outbox (channel, lane, not_before, id) where status = 'queued';
create index msg_outbox_event_idx on msg.outbox (event_id);
create index msg_outbox_done_idx on msg.outbox (done_at) where done_at is not null;
alter table msg.outbox enable row level security;

create table msg.push_sends (
  id            bigint generated always as identity primary key,
  outbox_id     bigint not null references msg.outbox (id) on delete cascade,
  sub_id        bigint references public.push_subs (id) on delete set null,
  status        text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed', 'gone')),
  not_before    timestamptz not null default now(),
  claim         uuid,
  claimed_until timestamptz,
  tries         int not null default 0,
  n429          int not null default 0,
  last_code     int,
  last_error    text,
  sent_at       timestamptz,
  updated_at    timestamptz not null default now(),
  unique (outbox_id, sub_id)
);
create index msg_push_sends_due_idx on msg.push_sends (not_before, id) where status = 'queued';
create index msg_push_sends_lease_idx on msg.push_sends (claimed_until) where status = 'sending';
create index msg_push_sends_sub_idx on msg.push_sends (sub_id);
create index msg_push_sends_recent_idx on msg.push_sends (updated_at) where n429 > 0;
alter table msg.push_sends enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Route at insert. The before trigger runs after email_skip_paused (names in order),
--    so a row that trigger drops is never routed.
-- ---------------------------------------------------------------------------
alter table public.email_queue drop constraint email_queue_status_check;
alter table public.email_queue add constraint email_queue_status_check
  check (status = any (array['queued', 'sending', 'sent', 'skipped', 'failed', 'outbox']));

create function msg.route_event() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.user_id is not null and new.pushed_at is null and private.is_alert(new.kind)
     and exists (select 1 from msg.kinds k where k.kind = new.kind and k.channel = 'push' and k.route = 'outbox') then
    new.pushed_at := now();
    new.push_skip := case when new.status = 'queued' then 'outbox'
                          when new.status = 'skipped' and new.last_error = 'one email per login' then 'one per login'
                          else 'not queued' end;
  end if;
  if new.status = 'queued'
     and exists (select 1 from msg.kinds k where k.kind = new.kind and k.channel = 'email' and k.route = 'outbox') then
    new.status := 'outbox';
  end if;
  return new;
end $$;

create function msg.route_event_rows() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into msg.outbox (event_id, channel, lane, kind, user_id, to_email, dedupe_key, not_before, expires_at)
  select new.id, k.channel, k.lane, new.kind, new.user_id,
         coalesce(new.to_email, (select u.email::text from auth.users u where u.id = new.user_id)),
         new.id || ':' || k.channel,
         case k.channel when 'email' then new.due_at else new.created_at end,
         case k.channel when 'email' then greatest(new.due_at, new.created_at) else new.created_at end + k.ttl
    from msg.kinds k
   where k.kind = new.kind and k.route = 'outbox'
     and ((k.channel = 'push' and new.push_skip = 'outbox') or (k.channel = 'email' and new.status = 'outbox'))
  on conflict (dedupe_key) do nothing;
  return null;
end $$;

create trigger msg_route before insert on public.email_queue
  for each row execute function msg.route_event();
create trigger msg_route_rows after insert on public.email_queue
  for each row when (new.push_skip = 'outbox' or new.status = 'outbox')
  execute function msg.route_event_rows();

-- ---------------------------------------------------------------------------
-- 3. A "back"'s "down" on one channel, on either path: 'wait', 'ok', 'dropped'.
-- ---------------------------------------------------------------------------
create function msg.push_down_state(p_user uuid, p_pair_key text)
returns text language sql stable security definer set search_path = '' as $$
  select case
           when d.id is null then 'dropped'
           when d.push_skip = 'outbox' then
             case (select o.status from msg.outbox o where o.dedupe_key = d.id || ':push')
               when 'queued' then 'wait' when 'sent' then 'ok' else 'dropped' end
           when d.pushed_at is null then 'wait'
           when d.push_skip is null then 'ok'
           else 'dropped'
         end
    from (select 1) one
    left join public.email_queue d on d.user_id = p_user and d.key = p_pair_key
$$;

-- Why a pop-up must not go now: a drop reason, 'wait', or null (send it).
create function msg.push_guard(p_o msg.outbox)
returns text language sql stable security definer set search_path = '' as $$
  select case
           when p_o.expires_at <= now() then 'too old'
           when q.id is null then 'event gone'
           when q.plant_id is not null
                and not exists (select 1 from public.plant_users pu where pu.user_id = q.user_id and pu.plant_id = q.plant_id)
             then 'plant removed'
           when q.plant_id is not null and not exists (
                  select 1 from billing.seats se join billing.accounts ba on ba.id = se.account
                   where ba.user_id = q.user_id and se.plant = q.plant_id and se.closed_at is null)
             then 'plant not chosen'
           -- needs_relink is queued just before the login is marked broken (trigger order on
           -- sunsynk_accounts), so its plant is never read at send time: no live test for the login kinds
           when q.plant_id is not null and q.kind not in ('needs_relink', 'relinked')
                and not private.plant_live(q.user_id, q.plant_id) then 'plant not live'
           when not private.push_wanted(q.user_id, private.email_switch(q.kind)) then 'switched off'
           when q.pair_key is not null then
             case msg.push_down_state(q.user_id, q.pair_key)
               when 'wait' then 'wait' when 'dropped' then 'down had no pop-up' end
         end
    from (select 1) one
    left join public.email_queue q on q.id = p_o.event_id
$$;

-- Outbox rows whose device sends are all done: 'sent' if any device took it, else 'failed'.
create function msg.push_settle(p_ids bigint[])
returns void language sql security definer set search_path = '' as $$
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
$$;

-- ---------------------------------------------------------------------------
-- 4. Take
-- ---------------------------------------------------------------------------
create function public.msg_push_take(p_limit int default 200)
returns table (id bigint, claim uuid, event_id bigint, kind text, plant_id bigint, title text, body text,
               tab text, day text, endpoint text, p256dh text, auth text)
language plpgsql security definer set search_path = '' as $$
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
  select l.id, v_claim, q.id, q.kind, q.plant_id, pt.title, pt.body,
         t->>'tab',
         case when t->>'tab' in ('grid', 'solar') then t->>'day' end,
         ps.endpoint, ps.p256dh, ps.auth
    from leased l
    join msg.outbox o on o.id = l.outbox_id
    join public.email_queue q on q.id = o.event_id
    join public.push_subs ps on ps.id = l.sub_id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
    cross join lateral (select private.alert_text(q.kind, q.data, q.created_at, public.plant_tz(q.plant_id)) t) x
    cross join lateral private.push_text(q.kind, x.t, pu.plant_name,
      (select count(*)::int from public.plant_users n where n.user_id = q.user_id)) pt
   order by l.id;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Done: [{id, code, retry_s?, error?}]. code is the push service's HTTP status;
--    0 = no answer. Only the claim that leased a send can close it.
-- ---------------------------------------------------------------------------
create function public.msg_push_done(p_claim uuid, p_results jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_ids bigint[]; v_ok bigint[]; v_gone bigint[];
begin
  with res as (
    select (e->>'id')::bigint id, coalesce((e->>'code')::int, 0) code, (e->>'retry_s')::int retry_s, e->>'error' err
      from jsonb_array_elements(coalesce(p_results, '[]')) e),
  plan as (
    select s.id, r.code, r.err,
           r.code = 0 or r.code = 429 or r.code >= 500 as again,
           -- Retry-After 0 or past: still 5 s, or one pass would call the device in a loop
           now() + make_interval(secs => greatest(coalesce(r.retry_s, least(30 * 2 ^ greatest(s.tries - 1, 0), 600)), 5)) as next_at,
           o.expires_at
      from res r
      join msg.push_sends s on s.id = r.id and s.claim = p_claim and s.status = 'sending'
      join msg.outbox o on o.id = s.outbox_id),
  upd as (
    update msg.push_sends s
       set status = case when p.code between 200 and 299 then 'sent'
                         when p.code in (404, 410) then 'gone'
                         when p.again and p.next_at < p.expires_at then 'queued'
                         else 'failed' end,
           not_before = case when p.again then p.next_at else s.not_before end,
           sent_at = case when p.code between 200 and 299 then now() end,
           n429 = s.n429 + (p.code = 429)::int,
           last_code = p.code,
           last_error = case when p.code between 200 and 299 then null
                             when p.again and p.next_at >= p.expires_at then 'too old'
                             else left(coalesce(p.err, 'push service ' || p.code), 200) end,
           claim = null, claimed_until = null, updated_at = now()
      from plan p
     where s.id = p.id
    returning s.outbox_id, s.sub_id, s.status)
  select array_agg(distinct u.outbox_id),
         array_agg(u.sub_id) filter (where u.status = 'sent'),
         array_agg(u.sub_id) filter (where u.status = 'gone')
    into v_ids, v_ok, v_gone
    from upd u;

  update public.push_subs ps set last_ok_at = now() where ps.id = any (v_ok);
  delete from public.push_subs ps where ps.id = any (v_gone);
  perform msg.push_settle(v_ids);
end $$;

revoke all on function public.msg_push_take(int) from public, anon, authenticated;
revoke all on function public.msg_push_done(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.msg_push_take(int) to service_role;
grant execute on function public.msg_push_done(uuid, jsonb) to service_role;
revoke all on all functions in schema msg from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. push_claim: a "down" may be on the outbox. Its "back" waits while it is queued
--    there and is skipped unless it was sent. Body 0232 (0256, 0257 patches kept).
-- ---------------------------------------------------------------------------
do $$
declare
  d text := pg_get_functiondef('public.push_claim(int)'::regprocedure);
  skip_old text := $o$                   where d.user_id = q.user_id and d.key = q.pair_key and d.push_skip is null)$o$;
  wait_old text := $o$                      where q.pair_key is not null and d.user_id = q.user_id and d.key = q.pair_key and d.pushed_at is null)$o$;
begin
  if position(skip_old in d) = 0 or position(wait_old in d) = 0 then
    raise exception 'push_claim changed since 0257: edit it by hand';
  end if;
  d := replace(d, skip_old, $n$                   where d.user_id = q.user_id and d.key = q.pair_key
                     and (d.push_skip is null or (d.push_skip = 'outbox'                              -- 0261
                          and exists (select 1 from msg.outbox o where o.dedupe_key = d.id || ':push' and o.status = 'sent'))))$n$);
  d := replace(d, wait_old, $n$                      where q.pair_key is not null and d.user_id = q.user_id and d.key = q.pair_key
                        and (d.pushed_at is null or (d.push_skip = 'outbox'                           -- 0261
                             and exists (select 1 from msg.outbox o where o.dedupe_key = d.id || ':push' and o.status = 'queued'))))$n$);
  execute d;
end $$;

-- ---------------------------------------------------------------------------
-- 7. job-check: per channel and lane in use, queued count and oldest, and in the last
--    hour the rows that expired and the 429s.
-- ---------------------------------------------------------------------------
create function public.job_check_msg()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'channel', l.channel, 'lane', l.lane,
           'queued', (select count(*) from msg.outbox o where o.channel = l.channel and o.lane = l.lane and o.status = 'queued'),
           -- oldest due and not handled: an unleased row not waiting on its "down", or a device send due
           'oldest', least(
              (select min(o.not_before) from msg.outbox o
                where o.channel = l.channel and o.lane = l.lane and o.status = 'queued' and o.claimed_until is null
                  and o.not_before <= now() and (l.channel <> 'push' or msg.push_guard(o) is distinct from 'wait')),
              (select min(s.not_before) from msg.push_sends s join msg.outbox o on o.id = s.outbox_id
                where l.channel = 'push' and o.lane = l.lane and s.status in ('queued', 'sending') and s.not_before <= now()
                  and (s.status = 'queued' or s.claimed_until < now()))),
           'expired', (select count(*) from msg.outbox o where o.channel = l.channel and o.lane = l.lane
                         and o.done_at > now() - interval '1 hour'
                         and (o.drop_reason = 'too old' or o.last_error = 'too old')),
           'n429', (select coalesce(sum(s.n429), 0) from msg.push_sends s join msg.outbox o on o.id = s.outbox_id
                     where l.channel = 'push' and o.lane = l.lane and s.n429 > 0 and s.updated_at > now() - interval '1 hour'))
         order by l.channel, l.lane), '[]'::jsonb)
    from (select distinct k.channel, k.lane from msg.kinds k where k.route = 'outbox') l
$$;
revoke all on function public.job_check_msg() from public, anon, authenticated;
grant execute on function public.job_check_msg() to service_role;

-- ---------------------------------------------------------------------------
-- 8. Flip: pop-ups for every alert kind go through the outbox from now on.
-- ---------------------------------------------------------------------------
update msg.kinds set route = 'outbox' where channel = 'push';

notify pgrst, 'reload schema';
