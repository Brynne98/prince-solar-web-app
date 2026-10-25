-- ============================================================================
-- 0102 — Emails are queued when their cause happens, and sent from a queue. (SOLAR-183)
--
-- 0092's notify re-read every plant's last 30-60 minutes every minute to work out
-- what was due, sent 40 a minute, and stopped for everyone on one error. That does
-- not hold at thousands of plants (a load-shedding stage change is thousands of
-- "Grid off" in the same minute), and it got times and pairs wrong (SOLAR-157).
--
-- Now:
--   email_queue        one row per email per user, written once when its cause
--                      happens. unique (user_id, key) makes it happen once. notify
--                      claims rows in batches (skip locked), sends them through
--                      Resend's batch call and marks them sent, skipped or failed.
--   private.plant_alert_state / string_alert_state
--                      each plant's grid, readings, battery and string state,
--                      stepped by poll once per minute for the plants it just wrote
--                      (email_poll_step). A change of state queues the email, with
--                      the time it really happened.
--   email_sweep()      what only the clock can tell, once a minute from notify:
--                      no readings for 15 min, SunSynk down/back, daily reminders,
--                      reports due today.
--   triggers           welcome (email confirmed), history (import walk finished,
--                      or a user joins a plant already done), Reconnect (a login
--                      turns needs_relink), account deleted (api_account_delete).
--
-- Rules (decided 2026-10-25):
--   grid          off after 3 known minutes in a row with no grid, back after 2
--                 with grid; one Grid off per outage, its Grid back when it ends.
--                 Follows the real switch, not plant_config.has_grid. The first
--                 state ever seen is taken silently, so a plant that never had grid
--                 gets nothing, and a Grid back goes only after a Grid off.
--   batt_hot      hottest battery over 40 C; ends at 38 C or below.
--   bank_drift    charge 10+ points apart between inverters for an hour (separate
--                 banks only); ends under 8 points.
--   string_dead   a string under 1.5 V and 5 W for 12 samples while another string
--                 on its inverter makes over 200 W; ends when it has voltage again.
--                 These three: one email when it starts, then one a day while it
--                 lasts. No "back" email.
--   logger_stale  newest SunSynk reading for the plant over 15 min old while we
--                 are still polling it, and SunSynk itself is not down. Covers one
--                 login failing alone. Readings back when fresh again.
--   sunsynk_down  over half the logins tried in the last 10 min have had no good
--                 poll for 10 min because SunSynk failed (not our own errors), and
--                 at least 3 of them. Back when that is no longer true. Mailed to
--                 the users on the failing logins.
--   reports       queued from 07:00 local on the day; still sent later that day.
--
-- Replaces email_sent and email_outbox (their rows move into email_queue as sent)
-- and 0092's email_sunsynk_state, email_relinks, email_users, email_history_done.
-- email_plant_events stays: api_alerts_due_raw (alerts-due) still reads it.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- The queue
-- ---------------------------------------------------------------------------
create table if not exists public.email_queue (
  id          bigint generated always as identity primary key,
  user_id     uuid references auth.users (id) on delete cascade,
  to_email    text,                     -- account_deleted only: the user row is gone
  plant_id    bigint,
  kind        text not null,
  key         text not null,
  pair_key    text,                     -- a "back" email: the key of its "down"
  data        jsonb not null default '{}'::jsonb,
  priority    smallint not null default 1,   -- 0 alerts, 1 account, 2 reports
  due_at      timestamptz not null default now(),
  status      text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'skipped', 'failed')),
  tries       int not null default 0,
  last_error  text,
  batch_key   text,                     -- Resend idempotency key of the batch it last went in
  claimed_at  timestamptz,
  sent_at     timestamptz,
  created_at  timestamptz not null default now(),
  check (user_id is not null or to_email is not null),
  unique nulls not distinct (user_id, key)
);
create index if not exists email_queue_due_idx on public.email_queue (priority, due_at, id) where status = 'queued';
create index if not exists email_queue_sending_idx on public.email_queue (claimed_at) where status = 'sending';
create index if not exists email_queue_user_plant_idx on public.email_queue (user_id, plant_id);
alter table public.email_queue enable row level security;
revoke all on public.email_queue from public, anon, authenticated;
grant all on public.email_queue to service_role;

-- What 0092 sent (or marked as had) moves over, so nothing goes twice.
do $$
begin
  if to_regclass('public.email_sent') is not null then
    insert into public.email_queue (user_id, plant_id, kind, key, data, status, sent_at, created_at)
    select user_id, plant_id, kind, key, data, 'sent', sent_at, sent_at from public.email_sent
    on conflict do nothing;
  end if;
  if to_regclass('public.email_outbox') is not null then
    insert into public.email_queue (to_email, kind, key)
    select email, 'account_deleted', 'account_deleted:outbox:' || id from public.email_outbox
    on conflict do nothing;
  end if;
end $$;

-- One email to every user on a plant. Their own name for the plant is read at send.
create or replace function private.email_enqueue_plant(p_plant bigint, p_kind text, p_key text, p_data jsonb,
                                                       p_pair_key text default null, p_priority smallint default 0)
returns void language sql security definer set search_path = '' as $$
  insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
  select pu.user_id, p_plant, p_kind, p_key, p_pair_key, p_data, p_priority
    from public.plant_users pu where pu.plant_id = p_plant
  on conflict do nothing;
$$;

-- ---------------------------------------------------------------------------
-- Plant state, stepped by poll
-- ---------------------------------------------------------------------------
create table if not exists private.plant_alert_state (
  plant_id          bigint primary key references public.plant_config (plant_id) on delete cascade,
  -- grid: the state in force, the run of same-answer minutes that may change it
  grid_on           boolean,
  grid_since        bigint,
  grid_off_key      text,               -- set while a Grid off went out for this outage
  grid_run_on       boolean,
  grid_run_n        int not null default 0,
  grid_run_start    bigint,
  -- readings: newest SunSynk device time seen, epoch
  last_dev          bigint,
  stale             boolean not null default false,
  stale_key         text,
  -- battery temperature
  hot               boolean not null default false,
  hot_since         bigint,
  hot_temp          int,
  hot_at            bigint,
  hot_sent_at       timestamptz,
  hot_n             int not null default 0,
  -- charge spread between separate banks
  drift             boolean not null default false,
  drift_run_start   bigint,
  drift_since       bigint,
  drift_banks       jsonb,
  drift_sent_at     timestamptz,
  drift_n           int not null default 0,
  stepped_ts        bigint
);
create index if not exists plant_alert_state_dev_idx on private.plant_alert_state (last_dev) where not stale;
create index if not exists plant_alert_state_hot_idx on private.plant_alert_state (hot_sent_at) where hot;
create index if not exists plant_alert_state_drift_idx on private.plant_alert_state (drift_sent_at) where drift;

create table if not exists private.string_alert_state (
  plant_id     bigint not null references public.plant_config (plant_id) on delete cascade,
  sn           text not null,
  no           int not null,
  last_alive   bigint,                  -- newest sample with voltage
  dead_n       int not null default 0,  -- dead samples while a sibling made power, since last_alive
  dead         boolean not null default false,
  dead_since   bigint,
  sent_at      timestamptz,
  n            int not null default 0,
  primary key (plant_id, sn, no)
);
create index if not exists string_alert_state_dead_idx on private.string_alert_state (sent_at) where dead;

alter table private.sunsynk_accounts
  add column if not exists last_try_at timestamptz,
  add column if not exists last_try    text check (last_try in ('ok', 'sunsynk', 'ours'));

create table if not exists private.email_system_state (
  id             int primary key default 1 check (id = 1),
  sunsynk_down   boolean not null default false,
  outage_id      bigint not null default 0,
  down_since     bigint,
  up_at          timestamptz             -- when the last outage ended
);
insert into private.email_system_state (id) values (1) on conflict do nothing;

-- One plant at one minute, from the facts email_poll_step read for every plant at
-- once (f: present, dev, temp, spread, has_batt, shared). Reads no readings itself
-- except on a change of state.
create or replace function private.email_plant_apply(p_plant bigint, p_ts bigint, f jsonb)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  s private.plant_alert_state;
  present boolean := (f->>'present')::boolean;
  dev bigint := (f->>'dev')::bigint;
  temp int := (f->>'temp')::int;
  spread numeric := (f->>'spread')::numeric;
  k text;
begin
  insert into private.plant_alert_state (plant_id) values (p_plant) on conflict do nothing;
  select * into s from private.plant_alert_state where plant_id = p_plant for update;
  if s.stepped_ts is not null and p_ts <= s.stepped_ts then return; end if;

  -- Grid. Unknown minutes (no voltage reported) are skipped.
  if present is not null then
    if present is distinct from s.grid_run_on then
      s.grid_run_on := present; s.grid_run_n := 1; s.grid_run_start := p_ts;
    else
      s.grid_run_n := s.grid_run_n + 1;
    end if;
    if s.grid_on is distinct from s.grid_run_on and s.grid_run_n >= (case when s.grid_run_on then 2 else 3 end) then
      if s.grid_on is null then
        null;                                       -- first state seen: taken silently
      elsif not s.grid_run_on then
        k := 'grid_down:' || p_plant || ':' || s.grid_run_start;
        perform private.email_enqueue_plant(p_plant, 'grid_down', k, jsonb_build_object(
          'since', s.grid_run_start,
          'chargePct', (select round(a.soc)::int from public.agg_minute a
                         where a.plant_id = p_plant and a.ts between p_ts - 600 and p_ts and a.soc is not null
                         order by a.ts desc limit 1)));
        s.grid_off_key := k;
      elsif s.grid_off_key is not null then
        perform private.email_enqueue_plant(p_plant, 'grid_back', 'grid_back:' || p_plant || ':' || s.grid_since,
          jsonb_build_object('since', s.grid_since, 'at', s.grid_run_start), s.grid_off_key);
        s.grid_off_key := null;
      end if;
      s.grid_on := s.grid_run_on; s.grid_since := s.grid_run_start;
    end if;
  end if;

  -- Readings: SunSynk's own clock, the newest device_time on the plant this minute.
  if dev is not null and dev > coalesce(s.last_dev, 0) then
    s.last_dev := dev;
    if s.stale and extract(epoch from now()) - dev <= 900 then
      if s.stale_key is not null then
        perform private.email_enqueue_plant(p_plant, 'logger_back', 'logger_back:' || substr(s.stale_key, 14),
          jsonb_build_object('since', split_part(s.stale_key, ':', 3)::bigint, 'at', dev), s.stale_key);
      end if;
      s.stale := false; s.stale_key := null;
    end if;
  end if;

  -- Battery temperature: the hottest inverter this minute.
  if (f->>'has_batt')::boolean and temp is not null then
    s.hot_temp := temp; s.hot_at := p_ts;
    if not s.hot and temp > 40 then
      s.hot := true; s.hot_since := p_ts; s.hot_n := 1; s.hot_sent_at := now();
      perform private.email_enqueue_plant(p_plant, 'batt_hot', 'batt_hot:' || p_plant || ':' || p_ts || ':1',
        jsonb_build_object('at', p_ts, 'tempC', temp));
    elsif s.hot and temp <= 38 then
      s.hot := false;
    end if;
  end if;

  -- Charge spread between inverters' own batteries.
  if (f->>'has_batt')::boolean and not (f->>'shared')::boolean then
    if spread is not null then
      if spread >= 10 then
        s.drift_run_start := coalesce(s.drift_run_start, p_ts);
        s.drift_banks := (select jsonb_agg(jsonb_build_object('name', coalesce(nullif(m.alias, ''), 'Inverter ' || r.sn),
                                                              'chargePct', round(r.batt_soc)::int) order by m.ord nulls last, r.sn)
                            from public.readings r left join private.meta m on m.sn = r.sn
                           where r.plant_id = p_plant and r.ts = p_ts and r.batt_soc between 1 and 100);
        if not s.drift and p_ts - s.drift_run_start >= 3600 then
          s.drift := true; s.drift_since := s.drift_run_start; s.drift_n := 1; s.drift_sent_at := now();
          perform private.email_enqueue_plant(p_plant, 'bank_drift', 'bank_drift:' || p_plant || ':' || s.drift_since || ':1',
            jsonb_build_object('since', s.drift_since, 'banks', s.drift_banks));
        end if;
      else
        s.drift_run_start := null;
        if s.drift and spread < 8 then s.drift := false; end if;
      end if;
    end if;
  elsif s.drift or s.drift_run_start is not null then
    s.drift := false; s.drift_run_start := null;
  end if;

  s.stepped_ts := p_ts;
  update private.plant_alert_state set
    grid_on = s.grid_on, grid_since = s.grid_since, grid_off_key = s.grid_off_key,
    grid_run_on = s.grid_run_on, grid_run_n = s.grid_run_n, grid_run_start = s.grid_run_start,
    last_dev = s.last_dev, stale = s.stale, stale_key = s.stale_key,
    hot = s.hot, hot_since = s.hot_since, hot_temp = s.hot_temp, hot_at = s.hot_at, hot_sent_at = s.hot_sent_at, hot_n = s.hot_n,
    drift = s.drift, drift_run_start = s.drift_run_start, drift_since = s.drift_since, drift_banks = s.drift_banks,
    drift_sent_at = s.drift_sent_at, drift_n = s.drift_n, stepped_ts = s.stepped_ts
  where plant_id = p_plant;
end $$;

-- poll, once per shard per minute: how each login went, then the plants it wrote.
-- p_outcomes: [{"account": uuid, "outcome": "ok" | "sunsynk" | "ours"}]. The minute's
-- readings and strings are read once for all the plants, not per plant. One plant
-- failing must not stop the rest, nor poll.
create or replace function public.email_poll_step(p_ts bigint, p_outcomes jsonb, p_plants bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  todo bigint[];
  r record;
  failed jsonb := '[]'::jsonb;
begin
  update private.sunsynk_accounts a set last_try_at = now(), last_try = o.outcome
    from jsonb_to_recordset(coalesce(p_outcomes, '[]'::jsonb)) as o(account uuid, outcome text)
   where a.id = o.account and o.outcome in ('ok', 'sunsynk', 'ours');

  -- Plants with config (purged ones have none) not already stepped for this minute.
  -- The rows stay locked to the end, so a link kick polling the same account in the
  -- same minute waits here and then finds them stepped: strings are counted once.
  insert into private.plant_alert_state (plant_id)
  select c.plant_id from public.plant_config c where c.plant_id = any (coalesce(p_plants, '{}')) order by 1
  on conflict do nothing;
  select coalesce(array_agg(x.plant_id), '{}') into todo
    from (select s.plant_id from private.plant_alert_state s
           where s.plant_id = any (coalesce(p_plants, '{}')) and (s.stepped_ts is null or s.stepped_ts < p_ts)
           order by s.plant_id for update) x;

  -- Strings, all plants at once: a string with voltage is alive; one under 1.5 V and
  -- 5 W while another string on its inverter makes over 200 W counts a dead sample.
  insert into private.string_alert_state as st (plant_id, sn, no, last_alive, dead_n)
  select x.plant_id, x.sn, x.no, case when x.alive then p_ts end, case when x.alive then 0 else 1 end
    from (select s.plant_id, s.sn, s.no, coalesce(s.volt_v, 0) >= 1.5 as alive,
                 coalesce(s.volt_v, 0) < 1.5 and coalesce(s.power_w, 0) < 5
                   and exists (select 1 from public.strings o where o.plant_id = s.plant_id and o.ts = p_ts and o.sn = s.sn
                                  and o.no <> s.no and coalesce(o.power_w, 0) > 200) as dead_in_sun
            from public.strings s
           where s.plant_id = any (todo) and s.ts = p_ts) x
   where x.alive or x.dead_in_sun
  on conflict (plant_id, sn, no) do update set
    last_alive = coalesce(excluded.last_alive, st.last_alive),
    dead_n     = case when excluded.last_alive is not null then 0 when st.dead then st.dead_n else st.dead_n + 1 end,
    dead       = st.dead and excluded.last_alive is null;
  -- Strings dead in the sun for 12 samples: one email each.
  for r in
    select a.plant_id, a.sn, a.no, coalesce(a.last_alive + 60, p_ts - 900) as since,
           coalesce(nullif(m.alias, ''), 'Inverter ' || a.sn) as inverter
      from private.string_alert_state a left join private.meta m on m.sn = a.sn
     where a.plant_id = any (todo) and not a.dead and a.dead_n >= 12
     order by a.plant_id, m.ord nulls last, a.sn, a.no
  loop
    update private.string_alert_state set dead = true, dead_since = r.since, sent_at = now(), n = 1
     where plant_id = r.plant_id and sn = r.sn and no = r.no;
    perform private.email_enqueue_plant(r.plant_id, 'string_dead',
      'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.since || ':1',
      jsonb_build_object('string', 'String ' || r.no, 'inverter', r.inverter, 'since', r.since));
  end loop;

  -- Everything else from one read of the minute's readings. Grid present is
  -- q_grid_present's rule (0055): over 100 V among the rows with the newest
  -- device_time; null when nobody reported a voltage.
  for r in
    with rd as (
      select x.plant_id, x.sn, x.device_time, x.grid_volt_v, x.batt_temp_c, x.batt_soc
        from public.readings x where x.plant_id = any (todo) and x.ts = p_ts
    ), newest as (
      select plant_id, max(device_time) as dt from rd where grid_volt_v is not null group by plant_id
    )
    select c.plant_id, jsonb_build_object(
             'present', case when count(rd.grid_volt_v) = 0 then null
                             else coalesce(bool_or(rd.grid_volt_v > 100) filter (
                                    where rd.grid_volt_v is not null and rd.device_time is not distinct from n.dt), false) end,
             'dev', max(case when rd.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                             then extract(epoch from (rd.device_time::timestamp at time zone coalesce(c.timezone, 'Africa/Johannesburg')))::bigint end),
             'temp', round(max(rd.batt_temp_c) filter (where rd.batt_temp_c > 0 and rd.batt_temp_c < 80)),
             'spread', case when count(distinct rd.sn) filter (where rd.batt_soc between 1 and 100) >= 2
                            then max(rd.batt_soc) filter (where rd.batt_soc between 1 and 100)
                               - min(rd.batt_soc) filter (where rd.batt_soc between 1 and 100) end,
             'has_batt', coalesce(c.has_battery, true),
             'shared', coalesce(c.battery_banks = 'shared', false)) as f
      from public.plant_config c
      join rd on rd.plant_id = c.plant_id
      left join newest n on n.plant_id = c.plant_id
     where c.plant_id = any (todo)
     group by c.plant_id, c.timezone, c.has_battery, c.battery_banks
  loop
    begin
      perform private.email_plant_apply(r.plant_id, p_ts, r.f);
    exception when others then
      failed := failed || jsonb_build_object('plant', r.plant_id, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('plants', coalesce(array_length(todo, 1), 0), 'failed', failed);
end $$;

-- ---------------------------------------------------------------------------
-- The clock: once a minute from notify
-- ---------------------------------------------------------------------------
create or replace function public.email_sweep()
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  now_s bigint := extract(epoch from now())::bigint;
  sys private.email_system_state;
  tried int;
  failing int;
  down boolean;
  r record;
  n_stale int := 0;
  n_rem int := 0;
  n_rep int := 0;
begin
  select * into sys from private.email_system_state where id = 1 for update;

  -- SunSynk itself. A login counts when poll tried it in the last 10 minutes; it is
  -- failing when its last try was SunSynk's fault and nothing good came for 10 min.
  select count(*) filter (where a.last_try_at > now() - interval '10 minutes'),
         count(*) filter (where a.last_try_at > now() - interval '3 minutes' and a.last_try = 'sunsynk'
                            and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes')
    into tried, failing
    from private.sunsynk_accounts a where a.status = 'active';
  down := failing >= 3 and failing * 2 > tried;

  if down and not sys.sunsynk_down then
    sys.sunsynk_down := true; sys.outage_id := sys.outage_id + 1;
    sys.down_since := (select extract(epoch from min(coalesce(a.last_ok_at, a.linked_at)))::bigint
                         from private.sunsynk_accounts a
                        where a.status = 'active' and a.last_try = 'sunsynk' and a.last_try_at > now() - interval '3 minutes'
                          and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes');
  elsif not down and sys.sunsynk_down then
    -- Back: everyone told it was down hears it is back.
    insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
    select q.user_id, q.plant_id, 'sunsynk_back', 'sunsynk_back:' || sys.outage_id, q.key,
           jsonb_build_object('since', sys.down_since, 'at', now_s), 0
      from public.email_queue q
     where q.key = 'sunsynk_down:' || sys.outage_id
    on conflict do nothing;
    sys.sunsynk_down := false; sys.up_at := now();
  end if;
  if sys.sunsynk_down then
    -- Users on a failing login; one email each, about their first plant on it.
    -- Run every minute of the outage, so a login that fails later is told too.
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    select distinct on (pu.user_id) pu.user_id, pu.plant_id, 'sunsynk_down', 'sunsynk_down:' || sys.outage_id,
           jsonb_build_object('since', sys.down_since), 0
      from private.sunsynk_accounts a join public.plant_users pu on pu.account_id = a.id
     where a.status = 'active' and a.last_try = 'sunsynk' and a.last_try_at > now() - interval '3 minutes'
       and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes'
     order by pu.user_id, pu.linked_at
    on conflict do nothing;
  end if;
  update private.email_system_state set sunsynk_down = sys.sunsynk_down, outage_id = sys.outage_id, down_since = sys.down_since,
         up_at = sys.up_at
   where id = 1;

  -- No readings: 15 min since SunSynk's newest reading for the plant, while poll
  -- still tries a login on it (ours not running is not the inverter going quiet),
  -- and not during a SunSynk outage (that has its own email) nor in the 15 min
  -- after one, while readings that the outage held up come back.
  if not sys.sunsynk_down and (sys.up_at is null or sys.up_at < now() - interval '15 minutes') then
    for r in
      select s.plant_id, s.last_dev from private.plant_alert_state s
       where not s.stale and s.last_dev < now_s - 900
         and exists (select 1 from public.plant_users pu join private.sunsynk_accounts a on a.id = pu.account_id
                      where pu.plant_id = s.plant_id and a.status = 'active' and a.last_try in ('ok', 'sunsynk')
                        and a.last_try_at > now() - interval '3 minutes')
       for update of s skip locked
    loop
      update private.plant_alert_state set stale = true, stale_key = 'logger_stale:' || r.plant_id || ':' || r.last_dev
       where plant_id = r.plant_id;
      perform private.email_enqueue_plant(r.plant_id, 'logger_stale', 'logger_stale:' || r.plant_id || ':' || r.last_dev,
        jsonb_build_object('since', r.last_dev));
      n_stale := n_stale + 1;
    end loop;
  end if;

  -- Daily reminders while a problem lasts.
  for r in select plant_id, hot_since, hot_n, hot_temp, hot_at from private.plant_alert_state
            where hot and hot_sent_at < now() - interval '24 hours' for update skip locked loop
    update private.plant_alert_state set hot_sent_at = now(), hot_n = hot_n + 1 where plant_id = r.plant_id;
    perform private.email_enqueue_plant(r.plant_id, 'batt_hot', 'batt_hot:' || r.plant_id || ':' || r.hot_since || ':' || (r.hot_n + 1),
      jsonb_build_object('at', r.hot_at, 'tempC', r.hot_temp, 'since', r.hot_since));
    n_rem := n_rem + 1;
  end loop;
  for r in select plant_id, drift_since, drift_n, drift_banks from private.plant_alert_state
            where drift and drift_sent_at < now() - interval '24 hours' for update skip locked loop
    update private.plant_alert_state set drift_sent_at = now(), drift_n = drift_n + 1 where plant_id = r.plant_id;
    perform private.email_enqueue_plant(r.plant_id, 'bank_drift', 'bank_drift:' || r.plant_id || ':' || r.drift_since || ':' || (r.drift_n + 1),
      jsonb_build_object('since', r.drift_since, 'banks', r.drift_banks));
    n_rem := n_rem + 1;
  end loop;
  for r in select a.plant_id, a.sn, a.no, a.dead_since, a.n, coalesce(nullif(m.alias, ''), 'Inverter ' || a.sn) as inverter
             from private.string_alert_state a left join private.meta m on m.sn = a.sn
            where a.dead and a.sent_at < now() - interval '24 hours' for update of a skip locked loop
    update private.string_alert_state set sent_at = now(), n = n + 1 where plant_id = r.plant_id and sn = r.sn and no = r.no;
    perform private.email_enqueue_plant(r.plant_id, 'string_dead',
      'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.dead_since || ':' || (r.n + 1),
      jsonb_build_object('string', 'String ' || r.no, 'inverter', r.inverter, 'since', r.dead_since));
    n_rem := n_rem + 1;
  end loop;

  -- Reports from 07:00 local: weekly on Monday, monthly on the 1st, yearly on 1 January.
  with loc as (
    select pu.user_id, pu.plant_id, timezone(public.plant_tz(pu.plant_id), now()) as t
      from public.plant_users pu
  ), due as (
    select user_id, plant_id, t::date as d, p.period
      from loc, lateral (values ('week'), ('month'), ('year')) p(period)
     where extract(hour from t) >= 7
       and case p.period when 'week'  then extract(isodow from t) = 1
                         when 'month' then extract(day from t) = 1
                         else extract(day from t) = 1 and extract(month from t) = 1 end
  ), ins as (
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    select user_id, plant_id, 'report_' || period, 'report_' || period || ':' || plant_id || ':' || d,
           jsonb_build_object('today', d), 2
      from due
    on conflict do nothing
    returning 1
  )
  select count(*) into n_rep from ins;

  return jsonb_build_object('sunsynkDown', sys.sunsynk_down, 'tried', tried, 'failing', failing,
                            'stale', n_stale, 'reminders', n_rem, 'reports', n_rep);
end $$;

-- ---------------------------------------------------------------------------
-- Causes that are not readings
-- ---------------------------------------------------------------------------
-- Welcome: the email is confirmed (or arrives confirmed, as with Google).
create or replace function private.email_on_confirm()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.email_confirmed_at is not null and (tg_op = 'INSERT' or old.email_confirmed_at is null)
     and new.email is not null then
    insert into public.email_queue (user_id, kind, key, priority) values (new.id, 'welcome', 'welcome', 1)
    on conflict do nothing;
  end if;
  return null;
end $$;
drop trigger if exists email_on_confirm on auth.users;
create trigger email_on_confirm after insert or update of email_confirmed_at on auth.users
  for each row execute function private.email_on_confirm();

-- History: the plant's 60-day walk and its temperature walk are both done. The
-- temperature walk stops at today, which is yesterday after midnight: one day of
-- slack, so a walk ending just before midnight still counts.
create or replace function private.history_done(c public.plant_config)
returns boolean language sql stable as $$
  select c.backfill_next is null
     and (c.temp_next is null or c.temp_next >= public.today_tz(coalesce(c.timezone, 'Africa/Johannesburg')) - 1)
$$;

create or replace function private.email_on_history()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if private.history_done(new) and not private.history_done(old) then
    perform private.email_enqueue_plant(new.plant_id, 'history', 'history:' || new.plant_id, '{}'::jsonb, null, 1::smallint);
  end if;
  return null;
end $$;
drop trigger if exists email_on_history on public.plant_config;
create trigger email_on_history after update of backfill_next, temp_next on public.plant_config
  for each row execute function private.email_on_history();

-- A user who joins a plant whose walk is already done hears about it too.
create or replace function private.email_on_plant_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.plant_config c where c.plant_id = new.plant_id and private.history_done(c)) then
    insert into public.email_queue (user_id, plant_id, kind, key, priority)
    values (new.user_id, new.plant_id, 'history', 'history:' || new.plant_id, 1)
    on conflict do nothing;
  end if;
  return null;
end $$;
drop trigger if exists email_on_plant_user on public.plant_users;
create trigger email_on_plant_user after insert on public.plant_users
  for each row execute function private.email_on_plant_user();

-- Reconnect: a login turns needs_relink (poll's account_mark, its copies included).
create or replace function private.email_on_relink()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'needs_relink' and old.status is distinct from 'needs_relink' then
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    values (new.user_id,
            (select pu.plant_id from public.plant_users pu where pu.account_id = new.id order by pu.linked_at limit 1),
            'needs_relink', 'needs_relink:' || new.id || ':' || extract(epoch from now())::bigint,
            jsonb_build_object('account', new.id), 0)
    on conflict do nothing;
  end if;
  return null;
end $$;
drop trigger if exists email_on_relink on private.sunsynk_accounts;
create trigger email_on_relink after update of status on private.sunsynk_accounts
  for each row execute function private.email_on_relink();

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------
create or replace function private.email_switch(p_kind text)
returns text language sql immutable as $$
  select case
    when p_kind in ('grid_down', 'grid_back') then 'grid'
    when p_kind in ('batt_hot', 'bank_drift') then 'battery'
    when p_kind = 'string_dead' then 'panels'
    when p_kind in ('logger_stale', 'logger_back') then 'readings'
    when p_kind in ('sunsynk_down', 'sunsynk_back') then 'sunsynk'
    when p_kind = 'report_week' then 'weekly'
    when p_kind = 'report_month' then 'monthly'
    when p_kind = 'report_year' then 'yearly'
  end
$$;

-- Up to p_limit due emails with everything the sender needs, marked sending.
-- Rows nobody should get any more are marked skipped here and not returned:
-- the switch is off, the user no longer has the plant, welcome after a plant is
-- linked, or a "back" whose "down" never went. p_peek reads without claiming.
create or replace function public.email_claim(p_limit int, p_peek boolean default false)
returns table (id bigint, user_id uuid, to_email text, plant_id bigint, plant_name text, tz text,
               kind text, key text, data jsonb, tries int, switch text, unsub_token uuid, batch_key text)
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if not p_peek then
    -- A sender that died mid-batch: its claims go back on the queue.
    update public.email_queue q set status = 'queued', claimed_at = null
     where q.status = 'sending' and q.claimed_at < now() - interval '10 minutes';
  end if;

  create temp table if not exists _claim (id bigint primary key, skip text) on commit drop;
  truncate _claim;
  insert into _claim (id, skip)
  select q.id,
         case
           when sw is not null and q.user_id is not null and not public.email_wanted(q.user_id, sw) then 'switched off'
           when q.plant_id is not null and q.user_id is not null and q.kind <> 'needs_relink'
                and not exists (select 1 from public.plant_users pu where pu.user_id = q.user_id and pu.plant_id = q.plant_id)
             then 'plant removed'
           when q.kind = 'welcome' and exists (select 1 from public.plant_users pu where pu.user_id = q.user_id)
             then 'plant linked'
           when q.pair_key is not null and not exists (
                  select 1 from public.email_queue d where d.user_id is not distinct from q.user_id and d.key = q.pair_key
                     and d.status in ('sent', 'sending', 'queued'))
             then 'down not sent'
         end
    from (select q0.*, private.email_switch(q0.kind) as sw
            from public.email_queue q0
           where q0.status = 'queued' and q0.due_at <= now()
             -- a "back" waits while its "down" is still on its way
             and not exists (select 1 from public.email_queue d
                              where q0.pair_key is not null and d.user_id is not distinct from q0.user_id and d.key = q0.pair_key
                                and (d.status = 'sending' or (d.status = 'queued' and d.due_at > now())))
           order by q0.priority, q0.due_at, q0.id
           limit p_limit
           for update skip locked) q;

  if not p_peek then
    update public.email_queue q set status = 'skipped', last_error = c.skip
      from _claim c where c.id = q.id and c.skip is not null;
    update public.email_queue q set status = 'sending', claimed_at = now(), tries = q.tries + 1
      from _claim c where c.id = q.id and c.skip is null;
  end if;

  return query
  select q.id, q.user_id, coalesce(q.to_email, u.email::text), q.plant_id,
         coalesce(pu.plant_name, (select pu2.plant_name from public.plant_users pu2
                                   where pu2.user_id = q.user_id order by pu2.linked_at limit 1)),
         case when q.plant_id is not null then public.plant_tz(q.plant_id) else 'Africa/Johannesburg' end,
         q.kind, q.key, q.data, q.tries, private.email_switch(q.kind),
         case when private.email_switch(q.kind) is not null and q.user_id is not null and not p_peek
              then public.email_unsub_token(q.user_id) end,
         q.batch_key
    from _claim c
    join public.email_queue q on q.id = c.id
    left join auth.users u on u.id = q.user_id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
   where c.skip is null
   order by q.priority, q.due_at, q.id;
end $$;

-- The sender's verdict on claimed rows: [{"id", "status": sent|queued|failed|skipped,
-- "error", "retry_s", "batch_key", "refund"}]. queued = try again after retry_s;
-- batch_key = the Resend batch it went in, so a retry resends that batch under the
-- same key; refund = never tried (the run ran out of time), so it is not counted.
-- A deleted account's address goes once its email is done with.
create or replace function public.email_done(p_results jsonb)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.email_queue q
     set status     = r.status,
         last_error = r.error,
         sent_at    = case when r.status = 'sent' then now() end,
         claimed_at = null,
         batch_key  = coalesce(r.batch_key, q.batch_key),
         tries      = q.tries - case when r.refund then 1 else 0 end,
         due_at     = case when r.status = 'queued' then now() + make_interval(secs => coalesce(r.retry_s, 60)) else q.due_at end
    from jsonb_to_recordset(p_results) as r(id bigint, status text, error text, retry_s int, batch_key text, refund boolean)
   where q.id = r.id and q.status = 'sending' and r.status in ('sent', 'queued', 'failed', 'skipped');
  delete from public.email_queue where kind = 'account_deleted' and status in ('sent', 'failed', 'skipped');
$$;

-- ---------------------------------------------------------------------------
-- Delete my account: 0092's body, the address now queued directly
-- ---------------------------------------------------------------------------
create or replace function public.api_account_delete()
returns jsonb
language plpgsql
security definer
set search_path = public, private, vault, pg_temp
as $$
declare
  uid uuid := auth.uid();
  acc record;
  p bigint;
  mine bigint[];
  orphans bigint[];
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;

  for acc in select id from private.sunsynk_accounts where user_id = uid order by id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
  end loop;
  select coalesce(array_agg(plant_id order by plant_id), '{}') into mine
    from public.plant_users where user_id = uid;
  foreach p in array mine loop perform pg_advisory_xact_lock(p); end loop;
  select coalesce(array_agg(g order by g), '{}') into orphans
    from unnest(mine) g
   where not exists (select 1 from public.plant_users o where o.plant_id = g and o.user_id <> uid);

  for acc in select id, refresh_secret_id from private.sunsynk_accounts where user_id = uid loop
    if acc.refresh_secret_id is not null then delete from vault.secrets where id = acc.refresh_secret_id; end if;
    update private.inverters set account_id = null where account_id = acc.id;
  end loop;
  delete from private.sunsynk_accounts where user_id = uid;

  delete from public.plant_users where user_id = uid;
  perform private.plants_tombstone(orphans);

  -- notify sends "account deleted" to this address (SOLAR-157, SOLAR-183)
  insert into public.email_queue (to_email, kind, key, priority)
  select email, 'account_deleted', 'account_deleted:' || uid, 1 from auth.users where id = uid and email is not null
  on conflict do nothing;

  delete from public.profiles where user_id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(array_length(orphans, 1), 0));
end $$;
revoke all on function public.api_account_delete() from public, anon;
grant execute on function public.api_account_delete() to authenticated;

-- ---------------------------------------------------------------------------
-- Remove login: 0096's body, the user's email rows for those plants now in email_queue
-- ---------------------------------------------------------------------------
create or replace function public.api_link_disconnect(p_account uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, vault, pg_temp
as $$
declare
  uid uuid := auth.uid();
  p bigint;
  mine bigint[];
  gone bigint[];
  orphans bigint[];
  sid uuid;
begin
  if uid is null or not exists (select 1 from private.sunsynk_accounts where id = p_account and user_id = uid) then
    raise exception 'not your account';
  end if;

  -- account lock, then its plants ascending: the order every path uses. Holding
  -- the account lock means its hourly sync cannot add a plant under us.
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  select coalesce(array_agg(plant_id order by plant_id), '{}') into mine
    from public.plant_users where account_id = p_account and user_id = uid;
  foreach p in array mine loop perform pg_advisory_xact_lock(p); end loop;

  with d as (
    delete from public.plant_users where account_id = p_account and user_id = uid returning plant_id)
  select coalesce(array_agg(plant_id order by plant_id), '{}') into gone from d;

  delete from public.email_queue e
   where e.user_id = uid
     and ((e.plant_id = any (gone) and e.kind not like 'sunsynk_%') or e.key like 'needs_relink:' || p_account || ':%');

  select refresh_secret_id into sid from private.sunsynk_accounts where id = p_account;
  if sid is not null then delete from vault.secrets where id = sid; end if;
  update private.inverters set account_id = null where account_id = p_account;
  delete from private.sunsynk_accounts where id = p_account;

  select coalesce(array_agg(g order by g), '{}') into orphans
    from unnest(gone) g
   where not exists (select 1 from public.plant_users o where o.plant_id = g and o.user_id <> uid);
  perform private.plants_tombstone(orphans);

  return jsonb_build_object(
    'plantsRemoved', coalesce(array_length(gone, 1), 0),
    'queued',        coalesce(array_length(orphans, 1), 0));
end $$;
revoke all on function public.api_link_disconnect(uuid) from public, anon;
grant execute on function public.api_link_disconnect(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 0092's per-minute readers and tables, replaced by the above
-- ---------------------------------------------------------------------------
drop function if exists public.email_sunsynk_state();
drop function if exists public.email_relinks();
drop function if exists public.email_users();
drop function if exists public.email_history_done();
drop table if exists public.email_sent;
drop table if exists public.email_outbox;

revoke all on function private.email_enqueue_plant(bigint, text, text, jsonb, text, smallint) from public, anon, authenticated;
revoke all on function private.email_plant_apply(bigint, bigint, jsonb) from public, anon, authenticated;
revoke all on function public.email_poll_step(bigint, jsonb, bigint[]) from public, anon, authenticated;
revoke all on function public.email_sweep() from public, anon, authenticated;
revoke all on function public.email_claim(int, boolean) from public, anon, authenticated;
revoke all on function public.email_done(jsonb) from public, anon, authenticated;
grant execute on function public.email_poll_step(bigint, jsonb, bigint[]) to service_role;
grant execute on function public.email_sweep() to service_role;
grant execute on function public.email_claim(int, boolean) to service_role;
grant execute on function public.email_done(jsonb) to service_role;

notify pgrst, 'reload schema';
