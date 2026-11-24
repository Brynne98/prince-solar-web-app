-- ============================================================================
-- 0253 — SOLAR-650 Part B: the poll minute plan, sent in 5-second slots.
--
-- Design: reports/scale-solar-650-poll-waves.md, Part B (items 4-7), and the council
-- notes of 2026-11-24 (Sol, Neon).
--
-- Before: every shard worked out billing.reading_routes for the whole fleet, and the cron
-- job posted every shard at :00. Now:
--
--   poll_plan_build(minute)  once a minute: each plant read now, the login (lane) it is read
--                    through, and its shard. Same pick as poll_jobs_v2 (logins before claims,
--                    the earliest first). billing.account_status runs once per account here,
--                    not once per account per shard. Logins are packed heaviest first into
--                    the least-loaded shard with room: at most 28 inverters (a plant with none
--                    yet counts as one) and 10 logins a shard. A login is never split; one
--                    heavier than the cap gets a shard of its own. Shard 0 always exists (it
--                    retries the share login, sends the daily call totals, trims the run log).
--                    Each shard gets a slot 0/5/10/15/20 s into the minute (round robin), so
--                    readings still land before the page asks (12-42 s, SOLAR-70) until Part C.
--   poll_tick()      every 5 seconds: builds this minute's plan if there is none, then posts
--                    each shard whose slot has come, once (marked dispatched_at).
--   poll_plan_jobs(minute, shard)  what the poller reads when its call arrives: the planned
--                    rows, each checked again against today's state (login still active and
--                    ok, still lists the plant or the claim still holds, the account still reads
--                    it with an open seat), joined with today's token and plant version. A plant
--                    that fails the check is dropped and counted (poll_plan_shards.dropped).
--                    A missing plan raises; an empty one is fine.
--
-- The switch: private.poll_mode, 'shadow' (as shipped) or 'live'. Each minute's plan is
-- stamped with the mode it was built in, and both the old cron job and the tick ask the same
-- plan, so a minute is polled by one path only.
--   shadow: the old sunsynk-poll job polls as before. The tick builds the plan and, 20 s in,
--           compares it with poll_jobs_v2's pick at that moment and runs every shard's
--           poll_plan_jobs read (without polling). Counts in poll_plan_minutes, differing
--           plants in poll_plan_diffs.
--   live:   the tick posts the shards; the old job posts nothing.
--   update private.poll_mode set mode = 'live';    -- from the next minute
--   update private.poll_mode set mode = 'shadow';  -- back, from the next minute
--
-- Also:
--   poll_shards()    in a live minute, the plan's shards (job-check expects a run from each).
--   fn_call_states() a poll shard's last call counts only for 10 minutes, so a shard number
--                    the plan no longer uses does not stay failing for 5 hours.
--   purge-cron-log   the tick's run rows are kept 1 hour, not 7 days (12 runs a minute).
--   billing.seats (account): account_status counts seats with "closed_at is null or later",
--                    which the partial seat indexes cannot serve.
--
-- The single-login poll (a new login, Check) and plantsToPoll() keep poll_jobs_v2.
-- ============================================================================

create index if not exists seats_account on billing.seats (account);

create table private.poll_mode (
  id         boolean primary key default true check (id),
  mode       text not null default 'shadow' check (mode in ('shadow', 'live')),
  changed_at timestamptz not null default now()
);
insert into private.poll_mode default values;
alter table private.poll_mode enable row level security;

-- One row per planned minute, kept 7 days. The shadow check fills checked_at onwards.
create table private.poll_plan_minutes (
  minute     timestamptz primary key,
  mode       text not null,
  built_at   timestamptz not null,
  build_ms   int  not null,
  shards     int  not null,
  logins     int  not null,
  plants     int  not null,
  inverters  int  not null,
  checked_at timestamptz,
  missing    int,          -- read by poll_jobs_v2 at the check, not in the plan
  extra      int,          -- in the plan, not read by poll_jobs_v2 at the check
  moved      int,          -- in both, through another login
  dropped    int           -- planned rows poll_plan_jobs left out at the check
);
alter table private.poll_plan_minutes enable row level security;

-- Plants that differed at a shadow check, kept 7 days.
create table private.poll_plan_diffs (
  minute    timestamptz not null,
  plant     bigint not null,
  plan_lane uuid,
  live_lane uuid,
  primary key (minute, plant)
);
alter table private.poll_plan_diffs enable row level security;

-- The plan itself: rebuilt every minute, kept 10 minutes, not worth WAL.
create unlogged table private.poll_plan (
  minute    timestamptz not null,
  plant     bigint not null,
  account   uuid not null,
  lane      uuid not null,
  via_share boolean not null,
  shard     int not null,
  primary key (minute, plant)
);
create index poll_plan_shard on private.poll_plan (minute, shard);
alter table private.poll_plan enable row level security;

create unlogged table private.poll_plan_shards (
  minute        timestamptz not null,
  shard         int not null,
  slot_ms       int not null,
  logins        int not null,
  plants        int not null,
  inverters     int not null,
  dispatched_at timestamptz,
  read_at       timestamptz,
  jobs          int,
  dropped       int,
  primary key (minute, shard)
);
alter table private.poll_plan_shards enable row level security;

-- ---------------------------------------------------------------------------
-- The plan for one minute. Returns the minute's row; builds it only when there is none.
-- ---------------------------------------------------------------------------
create function private.poll_plan_build(p_minute timestamptz)
returns private.poll_plan_minutes
language plpgsql security definer set search_path = private, pg_temp as $$
declare
  cap_inv    constant int := 28;
  cap_logins constant int := 10;
  slots      constant int := 5;      -- 0, 5, 10, 15, 20 s
  t0  timestamptz := clock_timestamp();
  h   private.poll_plan_minutes;
  l   record;
  inv int[] := '{}';                  -- per shard (1-based here): inverters
  cnt int[] := '{}';                  -- per shard: logins
  pl  int[] := '{}';                  -- per shard: plants
  lanes uuid[] := '{}';
  shard_of int[] := '{}';
  best int;
  i    int;
begin
  select * into h from private.poll_plan_minutes where minute = p_minute;
  if found then return h; end if;
  perform pg_advisory_xact_lock(hashtext('private.poll_plan_build'));
  select * into h from private.poll_plan_minutes where minute = p_minute;
  if found then return h; end if;

  -- poll_jobs_v2's pick (0246), once for the fleet
  insert into private.poll_plan (minute, plant, account, lane, via_share, shard)
  select p_minute, r.plant, r.account, r.lane, r.via_share, 0
    from (select distinct on (r.plant) r.plant, r.account, r.lane, r.via_share
            from billing.reading_routes(now()) r
           order by r.plant, r.via_share, r.since, r.lane) r
    join billing.plants bp on bp.id = r.plant;

  for l in
    select pp.lane, count(*)::int as plants, sum(greatest(1, coalesce(iv.n, 0)))::int as w
      from private.poll_plan pp
      left join (select plant_id, count(*) as n from private.inverters group by plant_id) iv
        on iv.plant_id = pp.plant
     where pp.minute = p_minute
     group by pp.lane
     order by w desc, pp.lane
  loop
    best := null;
    for i in 1 .. coalesce(array_length(inv, 1), 0) loop
      if inv[i] + l.w <= cap_inv and cnt[i] < cap_logins and (best is null or inv[i] < inv[best]) then
        best := i;
      end if;
    end loop;
    if best is null then
      inv := inv || l.w; cnt := cnt || 1; pl := pl || l.plants;
      best := array_length(inv, 1);
    else
      inv[best] := inv[best] + l.w; cnt[best] := cnt[best] + 1; pl[best] := pl[best] + l.plants;
    end if;
    lanes := lanes || l.lane;
    shard_of := shard_of || (best - 1);
  end loop;
  if coalesce(array_length(inv, 1), 0) = 0 then
    inv := '{0}'; cnt := '{0}'; pl := '{0}';
  end if;

  update private.poll_plan pp set shard = x.shard
    from unnest(lanes, shard_of) as x (lane, shard)
   where pp.minute = p_minute and pp.lane = x.lane and x.shard <> 0;

  insert into private.poll_plan_shards (minute, shard, slot_ms, logins, plants, inverters)
  select p_minute, k - 1, ((k - 1) % slots) * 5000, cnt[k], pl[k], inv[k]
    from generate_subscripts(inv, 1) k;

  insert into private.poll_plan_minutes (minute, mode, built_at, build_ms, shards, logins, plants, inverters)
  values (p_minute, (select mode from private.poll_mode), t0,
          (extract(epoch from clock_timestamp() - t0) * 1000)::int,
          array_length(inv, 1), (select coalesce(sum(c), 0) from unnest(cnt) c),
          (select coalesce(sum(c), 0) from unnest(pl) c), (select coalesce(sum(c), 0) from unnest(inv) c))
  returning * into h;

  delete from private.poll_plan where minute < p_minute - interval '10 minutes';
  delete from private.poll_plan_shards where minute < p_minute - interval '10 minutes';
  if extract(minute from p_minute) = 0 then
    delete from private.poll_plan_minutes where minute < p_minute - interval '7 days';
    delete from private.poll_plan_diffs where minute < p_minute - interval '7 days';
  end if;
  return h;
end $$;
revoke all on function private.poll_plan_build(timestamptz) from public, anon, authenticated;

-- This minute's mode (building its plan if needed). The old cron job posts only in shadow.
create function private.poll_minute_mode()
returns text language sql volatile security definer set search_path = private, pg_temp as $$
  select (private.poll_plan_build(date_trunc('minute', now()))).mode
$$;
revoke all on function private.poll_minute_mode() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- What a shard reads when its call arrives. Columns as poll_jobs_v2.
-- ---------------------------------------------------------------------------
create function public.poll_plan_jobs(p_minute bigint, p_shard int)
returns table (
  plant_id bigint, plant_name text, timezone text, batt_positive_means text,
  backfill_next text, backfill_until text, backfill_tries int,
  temp_next text, temp_tries int, has_grid boolean,
  account_id uuid, user_id uuid, sunsynk_username text, access_token text, access_expires_at bigint,
  plant_version bigint)
language plpgsql volatile security definer set search_path = public, private, pg_temp as $$
declare
  m timestamptz := to_timestamp(p_minute);
  planned int;
  n int;
begin
  select s.plants into planned from private.poll_plan_shards s where s.minute = m and s.shard = p_shard;
  if not found then
    raise exception 'no poll plan for % shard %', m, p_shard using errcode = 'P0002';
  end if;

  return query
  with plan as (
    select * from private.poll_plan pp where pp.minute = m and pp.shard = p_shard
  ), live as (            -- the plan's accounts that still read (0246 reading_routes' test)
    select a.account from (select distinct plan.account from plan) a
     cross join lateral billing.account_status(a.account, now()) st
     where st.state in ('trialing', 'active', 'past_due') and not st.must_choose
  ), ok as (
    select plan.* from plan
      join live using (account)
     where exists (select 1 from billing.seats s where s.account = plan.account and s.plant = plan.plant
                      and s.chosen_at <= now() and (s.closed_at is null or s.closed_at > now()))
       and exists (select 1 from private.sunsynk_accounts sa where sa.id = plan.lane and sa.status = 'active'
                      and (sa.kind = 'share') = plan.via_share)
       and case when plan.via_share
                then exists (select 1 from billing.plant_claims c where c.plant = plan.plant and c.account = plan.account)
                else exists (select 1 from billing.logins l
                               join billing.login_plants lp on lp.login = l.id and lp.plant = plan.plant and lp.gone_at is null
                              where l.id = plan.lane and l.account = plan.account and l.status = 'ok') end
  )
  select p.plant,
         (select lp.plant_name from billing.login_plants lp
           where lp.plant = p.plant and lp.plant_name is not null order by lp.last_seen_at desc nulls last limit 1),
         coalesce(c.timezone, 'Africa/Johannesburg'), c.batt_positive_means,
         c.backfill_next::text, c.backfill_until::text, coalesce(c.backfill_tries, 0),
         c.temp_next::text, coalesce(c.temp_tries, 0), c.has_grid,
         sa.id, sa.user_id, sa.sunsynk_username, sa.access_token, sa.access_expires_at,
         bp.version
    from ok p
    join private.sunsynk_accounts sa on sa.id = p.lane
    join billing.plants bp on bp.id = p.plant
    left join public.plant_config c on c.plant_id = p.plant
   order by p.plant;
  get diagnostics n = row_count;

  update private.poll_plan_shards s set read_at = clock_timestamp(), jobs = n, dropped = planned - n
   where s.minute = m and s.shard = p_shard;
end $$;
revoke all on function public.poll_plan_jobs(bigint, int) from public, anon, authenticated;
grant execute on function public.poll_plan_jobs(bigint, int) to service_role;

-- ---------------------------------------------------------------------------
-- The shadow check: the plan against poll_jobs_v2's pick now, and every shard's read.
-- ---------------------------------------------------------------------------
create function private.poll_plan_check(p_minute timestamptz)
returns void language plpgsql security definer set search_path = private, pg_temp as $$
declare
  s record;
  v_dropped int := 0;
begin
  insert into private.poll_plan_diffs (minute, plant, plan_lane, live_lane)
  select p_minute, coalesce(pp.plant, j.plant_id), pp.lane, j.account_id
    from (select * from private.poll_plan where minute = p_minute) pp
    full join (select plant_id, account_id from public.poll_jobs_v2(0, 1)) j on j.plant_id = pp.plant
   where pp.lane is distinct from j.account_id;

  for s in select shard from private.poll_plan_shards where minute = p_minute order by shard loop
    perform count(*) from public.poll_plan_jobs(extract(epoch from p_minute)::bigint, s.shard);
  end loop;
  select coalesce(sum(x.dropped), 0) into v_dropped from private.poll_plan_shards x where x.minute = p_minute;

  update private.poll_plan_minutes h set
    checked_at = clock_timestamp(),
    missing = (select count(*) from private.poll_plan_diffs d where d.minute = p_minute and d.plan_lane is null),
    extra   = (select count(*) from private.poll_plan_diffs d where d.minute = p_minute and d.live_lane is null),
    moved   = (select count(*) from private.poll_plan_diffs d where d.minute = p_minute
                 and d.plan_lane is not null and d.live_lane is not null),
    dropped = v_dropped
   where h.minute = p_minute;
end $$;
revoke all on function private.poll_plan_check(timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Every 5 seconds. Returns the number of shards posted.
-- ---------------------------------------------------------------------------
create function private.poll_tick()
returns int language plpgsql security definer set search_path = private, pg_temp as $$
declare
  m  timestamptz := date_trunc('minute', clock_timestamp());
  h  private.poll_plan_minutes;
  ms int;
  s  record;
  n  int := 0;
begin
  h := private.poll_plan_build(m);
  if h.mode = 'live' then
    ms := (extract(epoch from clock_timestamp() - m) * 1000)::int;
    for s in
      update private.poll_plan_shards x set dispatched_at = clock_timestamp()
       where x.minute = m and x.dispatched_at is null and x.slot_ms <= ms
      returning x.shard, x.slot_ms
    loop
      perform private.call_fn('poll', jsonb_build_object(
        'minute', extract(epoch from m)::bigint, 'shard', s.shard, 'shards', h.shards, 'slot_ms', s.slot_ms), 55000);
      n := n + 1;
    end loop;
  elsif h.checked_at is null and clock_timestamp() >= m + interval '20 seconds' then
    perform private.poll_plan_check(m);
  end if;
  return n;
end $$;
revoke all on function private.poll_tick() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- poll_shards (0030): in a live minute, the plan's shards; otherwise as before.
-- ---------------------------------------------------------------------------
create or replace function private.poll_shards(p_per_shard int default 10)
returns table (shard int, shards int, delay_ms int)
language sql
stable
set search_path = pg_temp
as $$
  with h as (
    select minute, mode, shards from private.poll_plan_minutes order by minute desc limit 1
  ), n as (
    select greatest(1, ceil(count(*)::numeric / greatest(p_per_shard, 1)))::int as shards
      from private.sunsynk_accounts
     where status = 'active'
  )
  select s.shard, h.shards, s.slot_ms
    from h join private.poll_plan_shards s on s.minute = h.minute
   where h.mode = 'live'
  union all
  select s.i, n.shards, (s.i % 3) * 10000
    from n, generate_series(0, n.shards - 1) as s(i)
   where not exists (select 1 from h where h.mode = 'live')
$$;

-- ---------------------------------------------------------------------------
-- fn_call_states (0181): a poll shard's last call counts for 10 minutes only. Only the line
-- marked 0253 changed.
-- ---------------------------------------------------------------------------
create or replace function private.fn_call_states()
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
begin
  -- plpgsql, not sql: net._http_response is missing on the local stack, and a sql body is
  -- checked when it is created.
  return (with c as (
    select f.fn, f.shard, f.at, f.id, f.timeout_ms,
           r.id is not null as answered,
           case when r.id is null then 'no answer'
                when r.timed_out then 'timeout'
                when r.error_msg is not null then 'error'
                when r.status_code between 200 and 299 then null
                else r.status_code::text end as bad,
           left(coalesce(r.error_msg, ''), 200) as error
      from private.fn_calls f
      left join net._http_response r on r.id = f.id
     where f.at > now() - interval '5 hours'
  ), last as (
    select distinct on (fn, shard) *
      from c
     where (answered or at < now() - timeout_ms * interval '1 millisecond' - interval '2 minutes')
       and (fn <> 'poll' or at > now() - interval '10 minutes')                -- 0253
     order by fn, shard, at desc
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'fn', fns.fn,
           'failing', (select bool_or(l.bad is not null) from last l where l.fn = fns.fn),
           'result', (select string_agg(distinct l.bad, ',') from last l where l.fn = fns.fn),
           'error', (select max(nullif(l.error, '')) from last l where l.fn = fns.fn and l.bad is not null),
           'last_call', (select max(l.at) from last l where l.fn = fns.fn),
           'failed_1h', (select count(*) from c where c.fn = fns.fn and c.bad is not null and c.answered
                                                  and c.at > now() - interval '1 hour'))
         order by fns.fn), '[]')
    from (select distinct fn from private.fn_calls where at > now() - interval '2 days') fns);
end $$;
revoke all on function private.fn_call_states() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Cron: the tick every 5 s; sunsynk-poll posts only in a shadow minute; purge-cron-log
-- keeps the tick's rows 1 hour. Production only (no pg_cron/pg_net locally).
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - skipping poll-tick (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'poll-tick') then
    perform cron.unschedule('poll-tick');
  end if;
  perform cron.schedule('poll-tick', '5 seconds', $c$select private.poll_tick()$c$);
  perform cron.alter_job(job_id := (select jobid from cron.job where jobname = 'sunsynk-poll'),
    command := $c$with m as materialized (select private.poll_minute_mode() as mode)
select private.call_fn('poll', jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms), 55000)
  from m, private.poll_shards() s where m.mode = 'shadow'$c$)
   where exists (select 1 from cron.job where jobname = 'sunsynk-poll');
  perform cron.alter_job(job_id := (select jobid from cron.job where jobname = 'purge-cron-log'),
    command := $c$delete from cron.job_run_details where end_time < now() - make_interval(days => 7)
   or (jobid = (select jobid from cron.job where jobname = 'poll-tick') and end_time < now() - interval '1 hour')$c$)
   where exists (select 1 from cron.job where jobname = 'purge-cron-log');
end $$;
