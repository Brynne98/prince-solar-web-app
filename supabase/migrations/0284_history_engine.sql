-- SOLAR-686 (reports/rework-step-3-history.md): one engine for every past day.
--
-- Schema `history`, owned by the History part:
--   history.imports          one open import per plant (H3): a link, a restart or a seat switch
--   history.import_accounts  the accounts on an import, each with its own pace (H3, H4)
--   history.days             every past day to fetch: minutes or extras (temperatures, volts, Hz),
--                            for an import, a hole the reader saw (gap) or the 6-hourly check (H1, H11)
--   history.totals           the brand's kWh totals per plant, nightly or in full (H2)
--   history.lanes            per login: back-off after a 429 (H7)
--   history.calls            import calls handed out per minute, for the fleet cap (H9)
-- Billing and Plants call history.start, history.leave and history.stop; nothing else writes here.
--
-- One transaction: the tables, the functions, the copy of today's bookmarks and queues into the
-- new tables, the compare (raises unless 0 differences), the callers switched, the old cron jobs
-- off. The old columns and tables (plant_config.backfill_*, temp_*, billing.history_fetches,
-- history_lanes, private.refill_queue, private.recover_kicks) are dropped one release later (H23).

-- one transaction: the CLI adds none. A lock it cannot have in 5 s stops the release (it is run
-- again) rather than holding the reader up behind it (H21, H23).
begin;
set local lock_timeout = '5s';

create schema history;
revoke all on schema history from public, anon, authenticated;
grant usage on schema history to service_role;

create table history.imports (
  id            bigint generated always as identity primary key,
  plant         bigint not null references plants.plants (id) on delete cascade,
  reason        text not null check (reason in ('link', 'restart', 'switch')),
  status        text not null default 'open' check (status in ('open', 'done', 'stopped')),
  requested_at  timestamptz not null,
  started_at    timestamptz,
  next_at       timestamptz,
  lane          uuid,
  floor_day     date not null,
  top_day       date not null,
  finished_at   timestamptz,
  stop_reason   text
);
create unique index imports_one_open on history.imports (plant) where status = 'open';
create index imports_lane on history.imports (lane, started_at);

create table history.import_accounts (
  import        bigint not null references history.imports (id) on delete cascade,
  account       uuid not null,
  reason        text not null check (reason in ('link', 'restart', 'switch')),
  pace_s        integer not null default 0 check (pace_s >= 0),
  fetch_no      integer not null default 0,
  requested_at  timestamptz not null,
  left_at       timestamptz,
  primary key (import, account)
);

create table history.days (
  id            bigint generated always as identity primary key,
  plant         bigint not null references plants.plants (id) on delete cascade,
  import        bigint references history.imports (id) on delete set null,
  day           date not null,
  kind          text not null check (kind in ('minutes', 'extras')),
  why           text not null check (why in ('import', 'gap', 'check')),
  grid_only     boolean not null default false,
  status        text not null default 'queued' check (status in ('queued', 'done', 'given_up', 'dropped')),
  tries         integer not null default 0,
  due_at        timestamptz not null,
  claim         uuid,
  claimed_until timestamptz,
  lane          uuid,
  version       bigint,
  calls         integer,
  shard         integer,
  note          text,
  created_at    timestamptz not null default now(),
  closed_at     timestamptz
);
-- one open row per plant, day and kind (H1): a gap and an import never fetch a day twice
create unique index days_one_open on history.days (plant, day, kind) where status = 'queued';
create index days_due on history.days (due_at) where status = 'queued';
create index days_import on history.days (import, status);
create index days_closed on history.days (closed_at) where status <> 'queued';
create index days_lane on history.days (lane) where status = 'queued' and claimed_until is not null;

create table history.totals (
  plant         bigint primary key references plants.plants (id) on delete cascade,
  full_sweep    boolean not null default false,
  due_at        timestamptz not null,
  tries         integer not null default 0,
  claim         uuid,
  claimed_until timestamptz,
  lane          uuid,
  version       bigint,
  calls         integer,
  shard         integer,
  note          text
);
create index totals_lane on history.totals (lane) where claimed_until is not null;

create table history.lanes (
  lane          uuid primary key,
  backoff_s     integer not null default 0,
  backoff_until timestamptz
);

-- per minute and group: each group of 25 logins spends its share of the fleet cap, so no group
-- waits on another's lock (H9)
create table history.calls (
  minute        timestamptz not null,
  shard         integer not null,
  calls         integer not null default 0,
  primary key (minute, shard)
);

revoke all on all tables in schema history from public, anon, authenticated;
grant all on all tables in schema history to service_role;

insert into public.app_config (key, value) values ('HISTORY_DAYS', 60), ('HISTORY_CALLS_PER_MINUTE', 600)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- settings and small helpers

create function history.setting(p_key text, p_default integer) returns integer
  language sql stable security definer set search_path to '' as $$
  select coalesce((select c.value::integer from public.app_config c where c.key = p_key), p_default)
$$;

-- the days an import reaches back (H5: a setting, not a literal)
create function history.days_back() returns integer
  language sql stable security definer set search_path to '' as $$
  select history.setting('HISTORY_DAYS', 60)
$$;

-- calls a step will make (H9): inverters x calls per inverter-day; totals by sweep
create function history.cost(p_kind text, p_plant bigint, p_grid_only boolean, p_full boolean) returns integer
  language sql stable security definer set search_path to '' as $$
  select case p_kind
           when 'totals' then case when p_full then 17 else 3 end
           else greatest(1, (select count(*) from plants.inverter_info i where i.plant_id = p_plant))::integer
                * case when p_kind = 'minutes' then 4 when p_grid_only then 1 else 2 end
         end
$$;

-- does the plant hold a day's temperatures already (an import after a switch back skips it): for
-- every inverter, most of the day's samples with both temperatures (the web host's day carries
-- AC only); read along each serial's key
create function history.has_extras(p_plant bigint, p_day date) returns boolean
  language sql stable security definer set search_path to '' as $$
  with b as (select public.day_start_epoch_tz(p_day, plants.tz(p_plant)) lo,
                    public.day_start_epoch_tz(p_day + 1, plants.tz(p_plant)) hi),
  inv as (select i.sn from plants.inverter_info i where i.plant_id = p_plant)
  select exists (select 1 from inv)
     and not exists (
       select 1 from inv, b
        where (select count(*) from public.inverter_history h
                where h.plant_id = p_plant and h.sn = inv.sn and h.ts >= b.lo and h.ts < b.hi
                  and h.ac_c is not null and h.dc_c is not null) < 100
          and (select count(*) from public.inverter_history_5m h
                where h.plant_id = p_plant and h.sn = inv.sn and h.ts >= b.lo and h.ts < b.hi
                  and h.ac_max is not null and h.dc_max is not null) < 100)
$$;

-- the oldest minute History may fill for a plant: its first stored minute or its oldest import
create function history.floor_ts(p_plant bigint) returns bigint
  language sql stable security definer set search_path to '' as $$
  select least((select min(a.ts) from public.agg_minute a where a.plant_id = p_plant),
               (select public.day_start_epoch_tz(min(i.floor_day), plants.tz(p_plant))
                  from history.imports i where i.plant = p_plant and i.status <> 'stopped'))
$$;

-- ---------------------------------------------------------------------------
-- the front door: start, leave, stop (H3, H8, H15)

-- Ask for a plant's past days. p_account null: every account that reads the plant now (a link,
-- a restart from Plants). Nothing is queued for a plant no account may read (H8). A second ask
-- on an open import joins it; the walk keeps its days.
create function history.start(p_plant bigint, p_account uuid, p_reason text, p_pace_s integer default 0,
                              p_fetch_no integer default 0, p_at timestamptz default now()) returns bigint
  language plpgsql security definer set search_path to '' as $$
declare
  accs uuid[];
  imp bigint;
  tz text := plants.tz(p_plant);
  top date;
  n int := history.days_back();
begin
  if p_reason not in ('link', 'restart', 'switch') then
    raise exception 'history.start: unknown reason %', p_reason;
  end if;
  if private.history_deleting(p_plant) then return null; end if;
  if p_account is null then
    accs := array(select distinct r.account from billing.reading_routes(p_at) r where r.plant = p_plant order by 1);
  elsif billing.holds_plant(p_account, p_plant, p_at) then
    accs := array[p_account];
  end if;
  if coalesce(cardinality(accs), 0) = 0 then return null; end if;
  top := (p_at at time zone tz)::date - 1;

  select i.id into imp from history.imports i where i.plant = p_plant and i.status = 'open' for update;
  if imp is null then
    insert into history.imports (plant, reason, requested_at, floor_day, top_day)
    values (p_plant, p_reason, p_at, top - (n - 1), top) returning id into imp;
    -- newest first (H5): the walk orders by day; a gap or check row already open joins the import
    insert into history.days as d (plant, import, day, kind, why, due_at)
    select p_plant, imp, top - g, k, 'import', p_at
      from generate_series(0, n - 1) g cross join (values ('minutes'), ('extras')) x(k)
    on conflict (plant, day, kind) where status = 'queued'
    do update set import = excluded.import, why = 'import', grid_only = false;
    -- the kWh totals back to the first year (H2)
    insert into history.totals as t (plant, full_sweep, due_at) values (p_plant, true, p_at)
    on conflict (plant) do update set full_sweep = true, due_at = least(t.due_at, excluded.due_at);
  end if;
  insert into history.import_accounts as a (import, account, reason, pace_s, fetch_no, requested_at)
  select imp, x, p_reason, greatest(coalesce(p_pace_s, 0), 0), coalesce(p_fetch_no, 0), p_at from unnest(accs) x
  on conflict (import, account) do update
     set reason = excluded.reason, pace_s = excluded.pace_s, fetch_no = excluded.fetch_no,
         requested_at = excluded.requested_at, left_at = null;
  -- the fastest account on it sets the pace (H3): one at full speed brings the next step in now
  if coalesce(p_pace_s, 0) = 0 then
    update history.imports set next_at = least(next_at, p_at) where id = imp and started_at is not null;
  end if;
  return imp;
end $$;

-- One account no longer holds the plant (switched out). The import goes on for the others (H3);
-- with nobody left on it, it stops.
create function history.leave(p_plant bigint, p_account uuid, p_at timestamptz default now()) returns void
  language plpgsql security definer set search_path to '' as $$
declare imp bigint;
begin
  select i.id into imp from history.imports i where i.plant = p_plant and i.status = 'open' for update;
  if imp is null then return; end if;
  update history.import_accounts set left_at = p_at where import = imp and account = p_account and left_at is null;
  if not exists (select 1 from history.import_accounts a where a.import = imp and a.left_at is null) then
    perform history.stop_import(imp, 'switched_out', p_at);
  end if;
end $$;

create function history.stop_import(p_import bigint, p_reason text, p_at timestamptz) returns void
  language sql security definer set search_path to '' as $$
  update history.days set status = 'dropped', note = p_reason, closed_at = p_at, claim = null, claimed_until = null
   where import = p_import and status = 'queued';
  update history.imports set status = 'stopped', stop_reason = p_reason, finished_at = p_at
   where id = p_import and status = 'open';
$$;

-- The plant's history is being deleted: nothing more is fetched for it (H8, H15).
create function history.stop(p_plant bigint, p_reason text, p_at timestamptz default now()) returns void
  language plpgsql security definer set search_path to '' as $$
begin
  perform history.stop_import(i.id, p_reason, p_at) from history.imports i where i.plant = p_plant and i.status = 'open';
  update history.days set status = 'dropped', note = p_reason, closed_at = p_at, claim = null, claimed_until = null
   where plant = p_plant and status = 'queued';
  delete from history.totals where plant = p_plant;
end $$;

-- A hole the reader saw (H11): every local day it touches.
create function history.gap_queue(p_plant bigint, p_from bigint, p_to bigint, p_at timestamptz default now()) returns void
  language sql security definer set search_path to '' as $$
  insert into history.days (plant, day, kind, why, due_at)
  select p_plant, d::date, 'minutes', 'gap', p_at
    from generate_series((to_timestamp(p_from) at time zone plants.tz(p_plant))::date,
                         (to_timestamp(p_to) at time zone plants.tz(p_plant))::date, interval '1 day') d
  on conflict (plant, day, kind) where status = 'queued' do nothing
$$;

-- ---------------------------------------------------------------------------
-- the 6-hourly check (H11, H12) and the nightly totals (H2)

-- Each read plant: every day of the last 14 with minutes missing, and yesterday's temperatures
-- when it has none. Days older than the window that are still queued are given up (SOLAR-525).
create function history.check_queue(p_at timestamptz default now()) returns jsonb
  language plpgsql security definer set search_path to '' as $$
declare
  p bigint; tz text; today date; fl bigint; d date; lo bigint; hi bigint; have bigint;
  now_ts bigint := extract(epoch from p_at)::bigint;
  queued int := 0; extras int := 0; given_up int;
begin
  update history.days x set status = 'given_up', note = 'left the 14-day window', closed_at = p_at,
                            claim = null, claimed_until = null
   where x.status = 'queued' and x.why in ('gap', 'check')
     and x.day < (p_at at time zone plants.tz(x.plant))::date - 13
     and (x.claimed_until is null or x.claimed_until <= p_at);
  get diagnostics given_up = row_count;
  for p in select distinct r.plant from billing.reading_routes(p_at) r order by 1 loop
    tz := plants.tz(p);
    today := (p_at at time zone tz)::date;
    fl := history.floor_ts(p);
    continue when fl is null;
    for d in select today - g from generate_series(0, 13) g loop
      lo := greatest(public.day_start_epoch_tz(d, tz), (ceil(fl / 60.0) * 60)::bigint);
      hi := least(public.day_start_epoch_tz(d + 1, tz), ((now_ts - 600) / 60) * 60);
      continue when hi <= lo;
      select count(*) into have from public.agg_minute a
       where a.plant_id = p and a.ts >= lo and a.ts < hi and a.source <> 'poller_partial' and a.ts % 60 = 0;
      if have < (hi - lo) / 60 then
        insert into history.days (plant, day, kind, why, due_at) values (p, d, 'minutes', 'check', p_at)
        on conflict (plant, day, kind) where status = 'queued' do nothing;
        queued := queued + 1;
      end if;
    end loop;
    if not history.has_extras(p, today - 1) then
      insert into history.days (plant, day, kind, why, due_at) values (p, today - 1, 'extras', 'check', p_at)
      on conflict (plant, day, kind) where status = 'queued' do nothing;
      extras := extras + 1;
    end if;
  end loop;
  perform history.clean(p_at);
  return jsonb_build_object('minute_days', queued, 'extras_days', extras, 'given_up', given_up);
end $$;

-- Every read plant's kWh totals: nightly the recent months; on the plant's Sunday every year (H2).
create function history.totals_queue(p_at timestamptz default now()) returns integer
  language sql security definer set search_path to '' as $$
  with ins as (
    insert into history.totals as t (plant, full_sweep, due_at)
    select r.plant, extract(dow from p_at at time zone plants.tz(r.plant)) = 0, p_at
      from (select distinct plant from billing.reading_routes(p_at)) r
    on conflict (plant) do update set full_sweep = t.full_sweep or excluded.full_sweep, due_at = least(t.due_at, excluded.due_at)
    returning 1)
  select count(*)::integer from ins
$$;

-- Closed days go after 7 days, finished imports after 30 (H10).
create function history.clean(p_at timestamptz default now()) returns void
  language sql security definer set search_path to '' as $$
  delete from history.days where status <> 'queued' and closed_at < p_at - interval '7 days';
  delete from history.imports where status <> 'open' and finished_at < p_at - interval '30 days';
  delete from history.calls where minute < p_at - interval '1 day';
$$;

-- ---------------------------------------------------------------------------
-- the queue: take, renew, done (H6-H9)

-- Groups of 25 logins (H9): one cron call per group.
create function history.shards(p_at timestamptz default now()) returns table(shard integer, shards integer)
  language sql stable security definer set search_path to '' as $$
  with n as (select greatest(1, ceil(count(distinct r.lane) / 25.0))::integer as k from billing.reading_routes(p_at) r)
  select g, n.k from n, generate_series(0, n.k - 1) g
$$;

-- Billing's door for History (H8): does the account have an open seat on the plant (its plan's
-- state aside: a trial over or an unpaid plan keeps the seat, and the import waits)
create function billing.has_seat(p_account uuid, p_plant bigint, p_at timestamptz) returns boolean
  language sql stable security definer set search_path to '' as $$
  select exists (select 1 from billing.seats s where s.account = p_account and s.plant = p_plant
                    and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at))
$$;
revoke all on function billing.has_seat(uuid, bigint, timestamptz) from public, anon, authenticated;

-- An account whose seat on a plant closed (switched out) leaves its import; an import with nobody
-- left stops. A plant past its trial or over the seat count keeps its import and its days: it
-- waits until it is read again (H8).
create function history.tidy(p_at timestamptz) returns void
  language plpgsql security definer set search_path to '' as $$
begin
  update history.import_accounts a set left_at = p_at
    from history.imports i
   where i.id = a.import and i.status = 'open' and a.left_at is null
     and not billing.has_seat(a.account, i.plant, p_at);
  perform history.stop_import(i.id, case when private.history_deleting(i.plant) then 'deleted' else 'switched_out' end, p_at)
     from history.imports i
    where i.status = 'open'
      and (private.history_deleting(i.plant)
           or not exists (select 1 from history.import_accounts a where a.import = i.id and a.left_at is null));
end $$;

-- Hand out at most one step per login (lane) of this group: of a hole or check day, the import the
-- login is walking (or a new one: the account whose last import on the login started longest ago
-- first) and the plant's kWh totals, the one due longest ago, so none starves another. Only
-- through a route Billing reads now (H8), a login that is ok, not backed off, and not answered 429
-- by the reader in the last 2 minutes; within this group's share of the fleet cap (H9).
create function history.take(p_shard integer default 0, p_shards integer default 1, p_at timestamptz default now())
returns jsonb
  language plpgsql security definer set search_path to '' as $$
declare
  cap int := ceil(history.setting('HISTORY_CALLS_PER_MINUTE', 600)::numeric / greatest(p_shards, 1));
  used int;
  used0 int;
  out jsonb := '[]';
  ln uuid;
  r record;
  imp bigint;
  c int;
  cl uuid;
  got boolean;
begin
  if p_shards < 1 or p_shard < 0 or p_shard >= p_shards then
    raise exception 'history.take: shard % of %', p_shard, p_shards;
  end if;
  if p_shard = 0 then perform history.tidy(p_at); end if;
  used := coalesce((select hc.calls from history.calls hc where hc.minute = date_trunc('minute', p_at) and hc.shard = p_shard), 0);
  used0 := used;

  -- the routes and the plants' versions in one statement (one snapshot): a step carries the version
  -- its route was read at, so a route that changes before the write is refused (H8)
  create temp table if not exists _ht_route (plant bigint primary key, account uuid, lane uuid, version bigint) on commit drop;
  truncate _ht_route;
  -- one route per plant first, then this group's logins: a plant two accounts read is in one group
  insert into _ht_route
  select x.plant, x.account, x.lane, x.version from (
    select distinct on (rr.plant) rr.plant, rr.account, rr.lane, p.version
      from billing.reading_routes(p_at) rr
      join plants.login_info l on l.id = rr.lane and l.status = 'ok'
      join plants.plant_info p on p.id = rr.plant
     where not private.history_deleting(rr.plant)
     order by rr.plant,
              exists (select 1 from history.import_accounts ia join history.imports i on i.id = ia.import
                       where i.plant = rr.plant and i.status = 'open' and ia.left_at is null and ia.account = rr.account) desc,
              rr.via_share, rr.since, rr.account, rr.lane) x
   where abs(hashtext(x.lane::text)) % p_shards = p_shard
     and not plants.throttled(x.lane, p_at - interval '2 minutes')
     and not exists (select 1 from history.lanes hl where hl.lane = x.lane and hl.backoff_until > p_at);

  -- the logins in a new order each call, so the share of the cap is not always spent on the same ones
  for ln in select y.lane from (select distinct x.lane from _ht_route x) y order by random() loop
    exit when used >= cap;
    -- a take overlapping this one (a slow call into the next minute) leaves this login alone
    continue when not pg_try_advisory_xact_lock(hashtext('history.lane'), hashtext(ln::text));
    continue when exists (select 1 from history.days d where d.lane = ln and d.status = 'queued' and d.claimed_until > p_at)
               or exists (select 1 from history.totals t where t.lane = ln and t.claimed_until > p_at);
    -- the import this login is walking, when its next step is due; else a new one
    imp := null;
    select i.id into imp from history.imports i join _ht_route x on x.plant = i.plant and x.lane = ln
     where i.status = 'open' and i.started_at is not null and i.next_at <= p_at
       and exists (select 1 from history.import_accounts a where a.import = i.id and a.left_at is null and a.account = x.account)
     order by i.started_at, i.id limit 1;
    if imp is null and not exists (select 1 from history.imports i join _ht_route x on x.plant = i.plant and x.lane = ln
                                    where i.status = 'open' and i.started_at is not null and i.next_at <= p_at + interval '5 seconds'
                                      and exists (select 1 from history.import_accounts a
                                                   where a.import = i.id and a.left_at is null and a.account = x.account)) then
      select i.id into imp from history.imports i join _ht_route x on x.plant = i.plant and x.lane = ln
       where i.status = 'open' and i.started_at is null
         and exists (select 1 from history.import_accounts a where a.import = i.id and a.left_at is null and a.account = x.account)
       order by (select max(o.started_at) from history.imports o join history.import_accounts oa on oa.import = o.id
                  where o.lane = ln and o.id <> i.id
                    and oa.account in (select a.account from history.import_accounts a where a.import = i.id)) nulls first,
                i.requested_at, i.id
       limit 1;
    end if;

    -- the candidates, the one due longest ago first; a hole before totals before an import on a tie
    got := false;
    for r in
      select * from (
        (select 'day' as k, d.id, d.plant, d.kind, d.grid_only, false as full_sweep, d.due_at as due, 0 as pri, d.import
           from history.days d join _ht_route x on x.plant = d.plant and x.lane = ln
          where d.status = 'queued' and d.import is null and d.due_at <= p_at
            and (d.claimed_until is null or d.claimed_until <= p_at)
          order by (d.why = 'gap') desc, d.day desc, (d.kind = 'minutes') desc, d.id limit 1)
        union all
        (select 'totals', t.plant, t.plant, 'totals', false, t.full_sweep, t.due_at, 1, null::bigint
           from history.totals t join _ht_route x on x.plant = t.plant and x.lane = ln
          where t.due_at <= p_at and (t.claimed_until is null or t.claimed_until <= p_at)
          order by t.due_at, t.plant limit 1)
        union all
        (select 'day', d.id, d.plant, d.kind, d.grid_only, false, coalesce((select i.next_at from history.imports i where i.id = d.import), d.due_at), 2, d.import
           from history.days d
          where imp is not null and d.import = imp and d.status = 'queued' and d.due_at <= p_at
            and (d.claimed_until is null or d.claimed_until <= p_at)
          order by d.day desc, (d.kind = 'minutes') desc, d.id limit 1)) cand
      order by due, pri
    loop
      c := history.cost(r.kind, r.plant, r.grid_only, r.full_sweep);
      -- within the group's share: a step that does not fit gives way to this login's next one; the
      -- first step of a minute always goes, so a dear one (kWh totals, many inverters) is never
      -- shut out (the logins come in a new order each call)
      continue when used > 0 and used + c > cap;
      cl := gen_random_uuid();
      if r.k = 'day' then
        -- the import first, then the day (one lock order with step_done and stop: import, then day)
        if r.import is not null then
          update history.imports set started_at = coalesce(started_at, p_at), next_at = coalesce(next_at, p_at), lane = ln
           where id = r.import and status = 'open';
        end if;
        update history.days d set claim = cl, claimed_until = p_at + interval '90 seconds', lane = ln, calls = c, shard = p_shard,
                                  version = (select x.version from _ht_route x where x.plant = d.plant)
         where d.id = r.id and d.status = 'queued' and (d.claimed_until is null or d.claimed_until <= p_at);
      else
        update history.totals t set claim = cl, claimed_until = p_at + interval '90 seconds', lane = ln, calls = c, shard = p_shard,
                                    version = (select x.version from _ht_route x where x.plant = t.plant)
         where t.plant = r.id and (t.claimed_until is null or t.claimed_until <= p_at);
      end if;
      continue when not found;   -- another run took or closed it in the meantime
      used := used + c;
      got := true;
      out := out || jsonb_build_array((
        select jsonb_build_object(
          'step', r.k, 'id', r.id, 'claim', cl, 'plant', r.plant, 'version', x.version, 'kind', r.kind,
          'day', d.day, 'why', d.why, 'tries', coalesce(d.tries, 0), 'grid_only', r.grid_only, 'full', r.full_sweep, 'calls', c,
          -- the plant feed fills what inverter history cannot, for the days it still holds (H11)
          'feed', coalesce(d.why <> 'import' or d.day >= (p_at at time zone plants.tz(r.plant))::date - 13, false),
          'timezone', plants.tz(r.plant), 'brand', p.brand, 'vendor_plant_id', p.vendor_id,
          'login', jsonb_build_object('id', l.id, 'user_id', l.user_id, 'username', l.username, 'brand', l.brand,
                                      'access_token', tk.access_token, 'access_expires_at', tk.access_expires_at))
          from _ht_route x
          join plants.plant_info p on p.id = x.plant
          join plants.login_info l on l.id = ln
          join plants.login_tokens tk on tk.id = l.id
          left join history.days d on r.k = 'day' and d.id = r.id
         where x.plant = r.plant));
      exit;   -- one step per login
    end loop;
  end loop;
  insert into history.calls as hc (minute, shard, calls) values (date_trunc('minute', p_at), p_shard, used - used0)
  on conflict (minute, shard) do update set calls = hc.calls + excluded.calls;
  if p_shard = 0 then
    perform billing.heartbeat('history', p_at, jsonb_build_object('handed_out', jsonb_array_length(out)));
  end if;
  return out;
end $$;

-- The worker holds its step: another 90 s (H6).
create function history.renew(p_step text, p_id bigint, p_claim uuid, p_at timestamptz default now()) returns boolean
  language plpgsql security definer set search_path to '' as $$
begin
  if p_step = 'totals' then
    update history.totals set claimed_until = p_at + interval '90 seconds'
     where plant = p_id and claim = p_claim and claimed_until > p_at;
  else
    update history.days set claimed_until = p_at + interval '90 seconds'
     where id = p_id and status = 'queued' and claim = p_claim and claimed_until > p_at;
  end if;
  return found;
end $$;

-- The end of a step (H7). ok: done. failed: retried twice a minute apart, then given up.
-- throttled: the login backs off, doubling from 60 s to 1 h; no try spent. wait (no inverter
-- serials yet, out of time): handed back, no try spent. refused: the plant is not read now; the
-- step waits for tidy or a route. Only the holder of a live claim ends a step (H6). p_calls: the
-- calls the step made, so the fleet count is what was spent, not what was reserved (H9).
-- Locks: the import, then the day (as take and stop).
create function history.step_done(p_step text, p_id bigint, p_claim uuid, p_result text, p_note text default null,
                                  p_at timestamptz default now(), p_calls integer default null) returns jsonb
  language plpgsql security definer set search_path to '' as $$
declare
  d history.days;
  t history.totals;
  imp bigint;
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
    if t.claim is distinct from p_claim or t.claimed_until <= p_at then return jsonb_build_object('status', 'not_yours'); end if;
    perform history.spent(t.shard, t.calls, p_calls, p_at);
    if p_result = 'throttled' then perform history.back_off(t.lane, p_at); end if;
    if p_result = 'ok' or (p_result = 'failed' and t.tries + 1 >= 3) then
      if p_result = 'ok' then perform history.lane_ok(t.lane); end if;
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

  imp := (select x.import from history.days x where x.id = p_id);
  if imp is not null then perform 1 from history.imports where id = imp for update; end if;
  select * into d from history.days where id = p_id for update;
  if not found or d.status <> 'queued' then return jsonb_build_object('status', coalesce(d.status, 'gone')); end if;
  if d.claim is distinct from p_claim or d.claimed_until <= p_at then return jsonb_build_object('status', 'not_yours'); end if;
  perform history.spent(d.shard, d.calls, p_calls, p_at);

  if p_result = 'throttled' then
    wait_s := history.back_off(d.lane, p_at);
    update history.days set claim = null, claimed_until = null, due_at = p_at + make_interval(secs => wait_s) where id = p_id;
  elsif p_result in ('wait', 'refused') then
    update history.days set claim = null, claimed_until = null, note = coalesce(p_note, note),
                            due_at = p_at + case when p_result = 'wait' then interval '5 minutes' else interval '1 minute' end
     where id = p_id;
    -- the plant waits, not just this day: its other days would meet the same answer
    update history.imports set next_at = p_at + case when p_result = 'wait' then interval '5 minutes' else interval '1 minute' end
     where id = d.import and status = 'open';
    return jsonb_build_object('status', 'queued');
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
end $$;

-- the calls a step made, against what take reserved for it (H9)
create function history.spent(p_shard integer, p_reserved integer, p_calls integer, p_at timestamptz) returns void
  language sql security definer set search_path to '' as $$
  insert into history.calls as hc (minute, shard, calls)
  select date_trunc('minute', p_at), coalesce(p_shard, 0), greatest(p_calls - coalesce(p_reserved, 0), 0)
   where p_calls is not null and p_calls > coalesce(p_reserved, 0)
  on conflict (minute, shard) do update set calls = hc.calls + excluded.calls
$$;

-- seconds until the next step of any group is due, for an idle worker (H4: a paced import's next day)
create function history.next_due(p_at timestamptz default now()) returns integer
  language sql stable security definer set search_path to '' as $$
  select greatest(0, ceil(extract(epoch from least(
           (select min(i.next_at) from history.imports i where i.status = 'open' and i.started_at is not null),
           (select min(d.due_at) from history.days d where d.status = 'queued' and d.import is null and d.claimed_until is null),
           (select min(t.due_at) from history.totals t where t.claimed_until is null)) - p_at)))::integer
$$;

create function history.back_off(p_lane uuid, p_at timestamptz) returns integer
  language sql security definer set search_path to '' as $$
  insert into history.lanes as hl (lane, backoff_s, backoff_until) values (p_lane, 60, p_at + interval '60 seconds')
  on conflict (lane) do update set backoff_s = least(greatest(hl.backoff_s * 2, 60), 3600),
                                   backoff_until = p_at + make_interval(secs => least(greatest(hl.backoff_s * 2, 60), 3600))
  returning backoff_s
$$;

create function history.lane_ok(p_lane uuid) returns void
  language sql security definer set search_path to '' as $$
  update history.lanes set backoff_s = 0, backoff_until = null where lane = p_lane and backoff_s > 0
$$;

-- ---------------------------------------------------------------------------
-- writes (H8): the plant row first (version fence, read now), then the queue row (the claim)

create function history.held(p_step text, p_id bigint, p_claim uuid, p_at timestamptz) returns bigint
  language plpgsql security definer set search_path to '' as $$
declare pl bigint; v bigint;
begin
  if p_step = 'totals' then
    select t.plant, t.version into pl, v from history.totals t where t.plant = p_id;
  else
    select d.plant, d.version into pl, v from history.days d where d.id = p_id;
  end if;
  if pl is null then raise exception 'step % is not read now (gone)', p_id using errcode = '55000'; end if;
  perform billing.guard_write(pl, v, p_at);
  if private.history_deleting(pl) then
    raise exception 'plant % is not read now (being deleted)', pl using errcode = '55000';
  end if;
  if p_step = 'totals' then
    perform 1 from history.totals t where t.plant = p_id and t.claim = p_claim and t.claimed_until > p_at for share;
  else
    perform 1 from history.days d where d.id = p_id and d.status = 'queued' and d.claim = p_claim and d.claimed_until > p_at for share;
  end if;
  if not found then raise exception 'plant % is not read now (claim lost)', pl using errcode = '55000'; end if;
  return pl;
end $$;

create function history.bank_minutes(p_id bigint, p_claim uuid, p_rows jsonb, p_source text, p_at timestamptz default now())
returns integer
  language plpgsql security definer set search_path to '' as $$
declare pl bigint := history.held('day', p_id, p_claim, p_at); n int;
begin
  perform set_config('billing.guarded', 'on', true);
  n := public.q_insert_recovered(pl, p_rows, p_source);
  perform set_config('billing.guarded', 'off', true);
  return n;
end $$;

create function history.bank_extras(p_step text, p_id bigint, p_claim uuid, p_sn text, p_rows jsonb, p_at timestamptz default now())
returns integer
  language plpgsql security definer set search_path to '' as $$
declare pl bigint := history.held(p_step, p_id, p_claim, p_at); n int;
begin
  perform set_config('billing.guarded', 'on', true);
  n := public.q_insert_inverter_history(pl, p_sn, p_rows);
  perform set_config('billing.guarded', 'off', true);
  return n;
end $$;

create function history.bank_totals(p_id bigint, p_claim uuid, p_rows jsonb, p_at timestamptz default now())
returns integer
  language plpgsql security definer set search_path to '' as $$
declare pl bigint := history.held('totals', p_id, p_claim, p_at); v bigint;
begin
  v := (select t.version from history.totals t where t.plant = p_id);
  return public.q_upsert_plant_energy_v2(pl, v, p_rows, p_at);
end $$;

-- the minutes a day step fills: the whole day for an import, from the plant's floor otherwise;
-- never the last 10 minutes (the reader's); a complete row is never asked for (H11, H20)
create function history.missing(p_id bigint, p_at timestamptz default now()) returns table(ts bigint)
  language sql stable security definer set search_path to '' as $$
  with d as (select x.plant, x.day, x.import, plants.tz(x.plant) tz from history.days x where x.id = p_id),
  b as (
    select d.plant,
           case when d.import is null then greatest(public.day_start_epoch_tz(d.day, d.tz), (ceil(history.floor_ts(d.plant) / 60.0) * 60)::bigint)
                else public.day_start_epoch_tz(d.day, d.tz) end as lo,
           least(public.day_start_epoch_tz(d.day + 1, d.tz), extract(epoch from p_at)::bigint - 600) as hi
      from d)
  select g from b, generate_series(b.lo, b.hi - 60, 60) g
   where b.hi > b.lo and b.lo is not null
     and not exists (select 1 from public.agg_minute a where a.plant_id = b.plant and a.ts = g and a.source <> 'poller_partial')
     -- past 31 days a minute lives in its five-minute row (agg_minute_rollup): held, not missing
     and not exists (select 1 from public.agg_5m f where f.plant_id = b.plant and f.ts = g - g % 300)
   order by g
$$;

-- ---------------------------------------------------------------------------
-- what screens show (H16) and the mail (H17)

create function history.progress(p_plant bigint) returns jsonb
  language sql stable security definer set search_path to '' as $$
  with i as (select x.* from history.imports x where x.plant = p_plant and x.status = 'open'),
  q as (select d.kind, count(*) as total, count(*) filter (where d.status = 'queued') as todo,
               max(d.day) filter (where d.status = 'queued') as top
          from history.days d join i on d.import = i.id group by d.kind),
  s as (select public.today_tz(plants.tz(p_plant)) as today, plants.tz(p_plant) as tz)
  select jsonb_build_object(
    'fetching', exists (select 1 from i),
    'percent', case when exists (select 1 from i)
                    then floor(100.0 * coalesce(sum(q.total - q.todo), 0) / greatest(coalesce(sum(q.total), 0), 1))::int end,
    'floor', (select i.floor_day from i),
    'minutesTo', (select q.top from q where q.kind = 'minutes'),
    'extrasTo', (select q.top from q where q.kind = 'extras'),
    'days', case when exists (select 1 from i) then
              (select count(*) from s, generate_series(0, history.days_back() - 1) g(n)
                where exists (select 1 from public.agg_minute a
                               where a.plant_id = p_plant
                                 and a.ts >= public.day_start_epoch_tz(s.today - g.n, s.tz)
                                 and a.ts <  public.day_start_epoch_tz(s.today - g.n + 1, s.tz))
                   or exists (select 1 from public.agg_5m f
                               where f.plant_id = p_plant
                                 and f.ts >= public.day_start_epoch_tz(s.today - g.n, s.tz)
                                 and f.ts <  public.day_start_epoch_tz(s.today - g.n + 1, s.tz)))
            else history.days_back() end,
    'window', history.days_back())
  from q
$$;

-- an import done: the "history ready" mail, once per plant and account (choice 1A: the mail key
-- is per plant, so a second import for the same account sends nothing)
create function history.import_done() returns trigger
  language plpgsql security definer set search_path to '' as $$
begin
  if new.status = 'done' and old.status = 'open' then
    delete from public.email_queue q
     where q.plant_id = new.plant and q.kind = 'history' and q.status = 'skipped' and q.last_error = 'not read';
    perform private.email_enqueue_plant(new.plant, 'history', 'history:' || new.plant, '{}'::jsonb, null, 1::smallint);
  end if;
  return null;
end $$;
create trigger import_done after update of status on history.imports
  for each row execute function history.import_done();

-- has this plant's history been ready once (a second account listing it gets its mail, H17)
create function history.ready(p_plant bigint) returns boolean
  language sql stable security definer set search_path to '' as $$
  select exists (select 1 from history.imports i where i.plant = p_plant and i.status = 'done')
      or (not exists (select 1 from history.imports i where i.plant = p_plant and i.status = 'open')
          and exists (select 1 from public.agg_minute a where a.plant_id = p_plant))
$$;

-- job-check (H10): the queue has stopped, not just busy: work due for over 30 minutes on read
-- plants and no step ended in the last 30 minutes (a big burst under the fleet cap is busy, not
-- stuck; a slowed import is not due)
create function history.stuck(p_at timestamptz default now()) returns jsonb
  language sql stable security definer set search_path to '' as $$
  with due as (
    select d.plant from history.days d
      left join history.imports i on i.id = d.import
     where d.status = 'queued' and (d.claimed_until is null or d.claimed_until <= p_at)
       and coalesce(i.next_at, d.due_at) < p_at - interval '30 minutes' and d.due_at < p_at - interval '30 minutes'
       and d.plant in (select r.plant from billing.reading_routes(p_at) r))
  select jsonb_build_object(
    'waiting', (select count(*) from due),
    'last_step_at', (select max(d.closed_at) from history.days d),
    'stuck', exists (select 1 from due)
             and coalesce((select max(d.closed_at) from history.days d), '-infinity') < p_at - interval '30 minutes')
$$;

-- the edge's door (PostgREST reaches public only); the server key only (H25)
create function public.history_jobs(p_cmd text, p_args jsonb default '{}'::jsonb) returns jsonb
  language plpgsql security definer set search_path to '' as $$
begin
  return case p_cmd
    when 'take'      then history.take(coalesce((p_args->>'shard')::int, 0), coalesce((p_args->>'shards')::int, 1))
    when 'renew'     then to_jsonb(history.renew(p_args->>'step', (p_args->>'id')::bigint, (p_args->>'claim')::uuid))
    when 'done'      then history.step_done(p_args->>'step', (p_args->>'id')::bigint, (p_args->>'claim')::uuid,
                                            p_args->>'result', p_args->>'note', now(), (p_args->>'calls')::int)
    when 'next'      then to_jsonb(history.next_due())
    when 'missing'   then coalesce((select jsonb_agg(m.ts order by m.ts) from history.missing((p_args->>'id')::bigint) m), '[]')
    when 'minutes'   then to_jsonb(history.bank_minutes((p_args->>'id')::bigint, (p_args->>'claim')::uuid, p_args->'rows', p_args->>'source'))
    when 'extras'    then to_jsonb(history.bank_extras(p_args->>'step', (p_args->>'id')::bigint, (p_args->>'claim')::uuid,
                                                       p_args->>'sn', p_args->'rows'))
    when 'totals'    then to_jsonb(history.bank_totals((p_args->>'id')::bigint, (p_args->>'claim')::uuid, p_args->'rows'))
    when 'has_extras' then to_jsonb(history.has_extras((p_args->>'plant')::bigint, (p_args->>'day')::date))
    when 'check'     then history.check_queue()
    when 'totals_now' then to_jsonb(history.totals_now((p_args->>'plant')::bigint))
    when 'trim_plants' then coalesce((select jsonb_agg(p.id order by p.id) from plants.plant_info p), '[]')
    when 'stuck'     then history.stuck()
    when 'loading'   then to_jsonb(exists (select 1 from history.imports i where i.plant = (p_args->>'plant')::bigint and i.status = 'open'))
    else null
  end;
end $$;
revoke all on function public.history_jobs(text, jsonb) from public, anon, authenticated;
grant execute on function public.history_jobs(text, jsonb) to service_role;

-- a mail that needs fresh totals (notify) asks for them now
create function history.totals_now(p_plant bigint) returns boolean
  language sql security definer set search_path to '' as $$
  insert into history.totals as t (plant, full_sweep, due_at) values (p_plant, true, now())
  on conflict (plant) do update set full_sweep = true, due_at = least(t.due_at, excluded.due_at)
  returning true
$$;

-- H21: an import write never waits long on a lock the reader holds, and never runs long
alter function history.bank_minutes(bigint, uuid, jsonb, text, timestamptz) set lock_timeout = '1s';
alter function history.bank_minutes(bigint, uuid, jsonb, text, timestamptz) set statement_timeout = '10s';
alter function history.bank_extras(text, bigint, uuid, text, jsonb, timestamptz) set lock_timeout = '1s';
alter function history.bank_extras(text, bigint, uuid, text, jsonb, timestamptz) set statement_timeout = '10s';
alter function history.bank_totals(bigint, uuid, jsonb, timestamptz) set lock_timeout = '1s';
alter function history.bank_totals(bigint, uuid, jsonb, timestamptz) set statement_timeout = '10s';

-- every history function: the server only (H25)
revoke all on all functions in schema history from public, anon, authenticated;
grant execute on all functions in schema history to service_role;

-- ---------------------------------------------------------------------------
-- the reader's 429s per login (H9): the brand adapter marks, History reads (Plants' functions)

-- plpgsql: the column is added last (it locks plants.logins, which the reader writes every minute)
create function plants.throttled(p_login uuid, p_since timestamptz) returns boolean
  language plpgsql stable security definer set search_path to '' as $$
begin
  return coalesce((select l.throttled_at > p_since from plants.logins l where l.id = p_login), false);
end $$;
create function public.login_throttled(p_login uuid) returns void
  language plpgsql security definer set search_path to '' as $$
begin
  update plants.logins set throttled_at = now() where id = p_login;
end $$;
revoke all on function plants.throttled(uuid, timestamptz) from public, anon, authenticated;
grant execute on function plants.throttled(uuid, timestamptz) to service_role;
revoke all on function public.login_throttled(uuid) from public, anon, authenticated;
grant execute on function public.login_throttled(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- the callers, switched to History's front door (H15, H16, H17); whole functions

drop function billing.request_history(uuid, bigint[], timestamp with time zone, boolean);

CREATE OR REPLACE FUNCTION billing.request_history(p_account uuid, p_plants bigint[], p_at timestamp with time zone, p_counts boolean DEFAULT false, p_reason text DEFAULT 'switch'::text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  n int;
  target int;
  counted boolean;
begin
  if coalesce(cardinality(p_plants), 0) = 0 then return; end if;
  select (after->>'fetch_no')::int, coalesce((after->>'counted')::boolean, true) into n, counted from billing.account_events
   where account = p_account and kind = 'history_fetch' and at = p_at order by id limit 1;
  if n is null then
    counted := p_counts;
    n := case when counted then
           1 + (select count(*) from billing.account_events
                 where account = p_account and kind = 'history_fetch' and at > p_at - interval '7 days' and at < p_at
                   and coalesce((after->>'counted')::boolean, true))
         else 0 end;
    perform billing.log_event(p_account, p_at, 'system', 'history_fetch', null,
                              jsonb_build_object('fetch_no', n, 'counted', counted, 'plants', to_jsonb(p_plants)));
  end if;
  target := case when n <= 3 then 0 else least(1200 * power(2, least(n - 4, 10)), 86400)::int end;
  -- History's queue (SOLAR-686 H4): this account's pace on each plant's import
  perform history.start(x, p_account, p_reason, target, n, p_at) from unnest(p_plants) x;
end $function$;

CREATE OR REPLACE FUNCTION billing.apply_purchase(p_inv billing.invoices, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  m billing.markets;
  sid uuid;
  day int;
  pe timestamptz;
  had bigint[];
  restart boolean;
  old billing.subscriptions;
  tz text;
begin
  select mk.* into m from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = p_inv.account;
  tz := coalesce((select a.time_zone from billing.accounts a where a.id = p_inv.account), m.default_time_zone);
  restart := (billing.account_status(p_inv.account, p_at)).state = 'ended';
  old := billing.live_sub(p_inv.account);
  if old.id is not null then
    if old.cancel_at_period_end and old.period_end <= p_at then
      perform billing.end_sub(old.id, old.period_end, 'cancelled', p_at, 'paystack', false);
    else
      perform billing.end_sub(old.id, coalesce(billing.past_due_cutoff(old.past_due_since, m.retry_days, tz), p_at),
                              'unpaid', p_at, 'paystack', false);
    end if;
  end if;
  day := extract(day from p_at at time zone m.default_time_zone)::int;
  pe := billing.add_period(p_at, p_inv.interval, day, m.default_time_zone);
  insert into billing.subscriptions (account, price, plan, currency, interval, amount_minor, extra_place_minor,
                                     extra_places, offer, status, started_at, billing_day, period_start, period_end)
  values (p_inv.account, p_inv.price, p_inv.plan, p_inv.currency, p_inv.interval, p_inv.plan_amount_minor,
          p_inv.extra_place_minor, p_inv.extra_places, p_inv.offer, 'active', p_at, day, p_at, pe)
  returning id into sid;
  update billing.invoices set subscription = sid, period_start = p_at, period_end = pe where id = p_inv.id;
  -- paying in the free week ends the week and starts billing that day
  update billing.accounts set trial_ends_at = least(trial_ends_at, p_at)
   where id = p_inv.account and trial_started_at is not null;
  had := array(select plant from billing.seats where account = p_inv.account and closed_at is null);
  perform billing.lock_plants(p_inv.plants || had);
  perform billing.write_seats(p_inv.account, p_inv.plants, p_at);
  if restart then
    perform billing.request_history(p_inv.account, array(select x from unnest(p_inv.plants) x where x = any (had)), p_at, false, 'restart');
  end if;
end $function$;

CREATE OR REPLACE FUNCTION billing.write_seats(p_account uuid, p_want bigint[], p_at timestamp with time zone, p_reason text DEFAULT 'switched'::text, p_counts boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare had bigint[]; held boolean;
begin
  held := billing.reading_held(p_account, p_at);                                  -- 0256
  had := array(select plant from billing.seats where account = p_account and closed_at is null order by 1);
  update billing.seats set closed_at = p_at, close_reason = p_reason
   where account = p_account and closed_at is null and plant <> all (p_want);
  insert into billing.seats (account, plant, chosen_at)
  select p_account, x, p_at from unnest(p_want) x where x <> all (had);
  insert into billing.plant_facts as f (plant, trial_used_at, trial_used_by)
  select x, p_at, p_account from unnest(p_want) x where x <> all (had)
  on conflict (plant) do update set trial_used_at = coalesce(f.trial_used_at, excluded.trial_used_at),
                                    trial_used_by = coalesce(f.trial_used_by, excluded.trial_used_by)
   where f.trial_used_at is null or f.trial_used_by is null;
  perform plants.bump(array(select x from unnest(p_want || had) x where not (x = any (p_want) and x = any (had))));
  -- this account leaves the imports of the plants it switched out; another account's go on (SOLAR-686 H3)
  perform history.leave(x, p_account, p_at) from unnest(had) x where x <> all (p_want);
  -- a seat opening (or a plan restarting) on a deleted plant: it gathers history again. The
  -- caller holds the plant locks, so no write path has to touch the row.
  update billing.plant_facts set history_purged_at = null
   where plant = any (p_want) and history_purged_at is not null;
  -- a plant switched out that no account keeps is deleted now, under its lock, so the
  -- pop-up's "deleted now" holds even if the owner switches straight back
  perform billing.purge_now(x, p_at) from unnest(had) x where x <> all (p_want);
  perform billing.request_history(p_account, array(select x from unnest(p_want) x where x <> all (had)), p_at, p_counts);
  perform billing.readings_start(p_account, case when held then p_want                       -- 0256
                                      else array(select x from unnest(p_want) x where x <> all (had)) end, p_at);
end $function$;

CREATE OR REPLACE FUNCTION billing.purge_now(p_plant bigint, p_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare ps jsonb;
begin
  if not billing.is_live() then return null; end if;
  ps := billing.plant_state(p_plant, p_at);
  if ps->>'delete_at' is null or (ps->>'delete_at')::timestamptz > p_at or billing.payment_hold(p_plant, p_at) then
    return null;
  end if;
  -- 0277: the rows go in the background (private.history_delete_run); from here the plant
  -- is hidden, not read and not written while it waits
  insert into private.history_delete_queue (plant_id, queued_at) values (p_plant, clock_timestamp())
  on conflict (plant_id) do nothing;
  perform history.stop(p_plant, 'deleted', p_at);                          -- SOLAR-686 H8
  insert into billing.plant_facts (plant, history_purged_at) values (p_plant, p_at)
  on conflict (plant) do update set history_purged_at = excluded.history_purged_at;
  perform plants.bump(array[p_plant]);
  return jsonb_build_object('queued', 1);                                  -- 0277: delete_due counts it as deleted
end $function$;

CREATE OR REPLACE FUNCTION public.billing_jobs(p_cmd text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  return case p_cmd
    when 'login_seen'   then plants.list_seen((p_args->>'login')::uuid, p_args->'plants')
    when 'alerts'       then billing.alerts()
    when 'heartbeat'    then (select '{}'::jsonb from (select billing.heartbeat(p_args->>'job', now(), p_args->'result',
                               p_args->>'error')) x)
    when 'winback'      then billing.winback_return(p_args->>'reference')
    when 'outbox_sweep' then billing.outbox_sweep()
    when 'outbox_take'  then billing.outbox_take(coalesce((p_args->>'limit')::int, 50))
    when 'outbox_done'  then (select '{}'::jsonb from (select billing.outbox_done((p_args->>'id')::bigint,
                               (p_args->>'ok')::boolean, p_args->>'error', (p_args->>'retry_s')::int,
                               now(), coalesce((p_args->>'refund')::boolean, false))) x)
    else billing.unknown_command(p_cmd)
  end;
end $function$;

CREATE OR REPLACE FUNCTION public.plant_config_seed(p_rows jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  -- the brand's zone for the plant, when it gives a real one (R26); else the plant keeps its market's
  with z as (update plants.plants p set time_zone = r->>'timezone'
               from jsonb_array_elements(p_rows) r
              where p.id = (r->>'plant_id')::bigint and plants.tz_valid(nullif(r->>'timezone', ''))
                and p.time_zone is distinct from r->>'timezone' returning p.id)
  insert into public.plant_config (plant_id, currency, lat, lon, panel_azimuth, geometry_source)
  select (r->>'plant_id')::bigint,
         coalesce(nullif(upper(r->>'currency'), ''), 'ZAR'),
         nullif(r->>'lat', '')::double precision,
         nullif(r->>'lon', '')::double precision,
         case when nullif(r->>'lat', '')::double precision > 0 then 180 else 0 end,
         'default'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id) do nothing;
  -- the 60 days, for a plant that is read now (SOLAR-686 H8: History checks that); not paused
  select history.start((r->>'plant_id')::bigint, null, 'link')
    from jsonb_array_elements(p_rows) r
   where not coalesce((r->>'paused')::boolean, false)
$function$;

CREATE OR REPLACE FUNCTION private.plant_start_fill(p_plant bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  -- After a wipe that is running now, never under it.
  perform pg_advisory_xact_lock(p_plant);
  delete from private.plant_wipe where plant_id = p_plant;
  if not exists (select 1 from plants.settings where plant_id = p_plant) then
    -- Linked stopped, so never seeded (plants.ts syncPlants); the seed asks for the 60 days.
    perform public.plant_config_seed(jsonb_build_array(jsonb_build_object('plant_id', p_plant)));
  else
    -- the 60 days again, when the plant is read now (SOLAR-686 H8)
    perform history.start(p_plant, null, 'restart');
  end if;
  -- No readings counts from here (0174): the reading time kept from before the stop is old.
  insert into private.plant_alert_state (plant_id, started_at) values (p_plant, extract(epoch from now())::bigint)
  on conflict (plant_id) do update set started_at = excluded.started_at;
  perform public.plant_bootstrap_kick(p_plant);
end $function$;

CREATE OR REPLACE FUNCTION public.plant_bootstrap_kick(p_plant bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  fn_base text;
  auth jsonb;
  acc uuid;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net not enabled here - not kicking bootstrap for plant %', p_plant;
    return;
  end if;
  fn_base := private.functions_url();                                     -- 0280
  auth := jsonb_build_object(
    'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
    'Content-Type', 'application/json');
  -- the 60 days and the kWh totals are History's queue now (SOLAR-686 H1): taken within a minute
  select account_id into acc from plants.user_plants where plant_id = p_plant limit 1;
  if acc is not null then
    perform net.http_post(
      url := fn_base || '/poll',
      headers := auth,
      body := jsonb_build_object('account', acc),
      timeout_milliseconds := 55000);
  end if;
end $function$;

CREATE OR REPLACE FUNCTION public.poll_commit_batch(p_ts bigint, p_rows jsonb, p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(i integer, account uuid, result jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare
  accts uuid[];
  x uuid;
  t text;
  pl record;
begin
  if not billing.is_live() then
    raise exception 'poll_commit_batch needs billing live (0252)' using errcode = '55000';
  end if;
  -- a second batch in one transaction: the first one's tables are still there
  foreach t in array array['_bin', '_bok', '_brd', '_brw', '_bst', '_bsw', '_bme', '_bag', '_bgap'] loop
    if to_regclass('pg_temp.' || t) is not null then execute format('drop table pg_temp.%I', t); end if;
  end loop;

  create temp table _bin on commit drop as
    select e.n::int as i, (e.x->>'account')::uuid as account,
           coalesce(nullif(e.x->'versions', 'null'), '{}') as versions,
           e.x->>'access' as access, (e.x->>'expires')::bigint as expires,
           coalesce(nullif(e.x->'readings',  'null'), '[]') as readings,
           coalesce(nullif(e.x->'strings',   'null'), '[]') as strings,
           coalesce(nullif(e.x->'agg',       'null'), '[]') as agg,
           coalesce(nullif(e.x->'meta',      'null'), '[]') as meta,
           coalesce(nullif(e.x->'inverters', 'null'), '[]') as inverters
      from jsonb_array_elements(coalesce(p_rows, '[]')) with ordinality e (x, n);
  if exists (select 1 from _bin b where b.account is null) then
    raise exception 'poll_commit_batch: a row has no account' using errcode = '22023';
  end if;
  accts := array(select distinct b.account from _bin b order by 1);

  -- 1. logins: account_mark's locks, then the rows, in id order
  foreach x in array accts loop
    perform pg_advisory_xact_lock(1, hashtext(x::text));
  end loop;
  perform 1 from plants.login_info sa where sa.id = any (accts) order by sa.id for update;
  -- the newer token wins (0250): the last object with the latest expiry, when not older than the stored one
  perform plants.tokens_saved((select coalesce(jsonb_agg(jsonb_build_object('account', t.account, 'access', t.access, 'expires', t.expires)), '[]'::jsonb)
                                 from (select distinct on (b.account) b.account, b.access, b.expires from _bin b
                                        order by b.account, b.expires desc nulls last, b.i desc) t));

  -- 2. plants in id order, for share; a plant whose history was deleted for no key update,
  -- since step 8 updates it (two batches holding it for share would deadlock there). Then
  -- the version each read started on (looked up under the plant's own id, as write_allowed
  -- does) and read_now.
  for pl in select bp.id, (select f.history_purged_at from billing.plant_facts f where f.plant = bp.id) is not null as purged from plants.plant_info bp
            where bp.id in (select k::bigint from _bin b cross join jsonb_object_keys(b.versions) k)
            order by bp.id loop
    if pl.purged then
      perform 1 from plants.plant_info where id = pl.id for no key update;
    else
      perform 1 from plants.plant_info where id = pl.id for share;
    end if;
  end loop;
  create temp table _bok on commit drop as
    with v as (select distinct b.i, k::bigint as plant, b.versions->>(k::bigint::text) as version
                 from _bin b cross join jsonb_object_keys(b.versions) k)
    select v.i, v.plant from v
     where v.plant in (select pr from billing.plants_read_now(array(select distinct plant from v), greatest(p_at, clock_timestamp())) pr)   -- R20: the database's clock, after the locks
       and exists (select 1 from plants.plant_info bp where bp.id = v.plant and bp.version = v.version::bigint);
  -- one object sending an inverter twice fails in poll_commit_v2 (on conflict cannot update a
  -- row twice); here too, so the caller's login-by-login save fails that login alone
  if exists (select 1 from _bin b cross join jsonb_array_elements(b.inverters) e
              group by b.i, e->>'sn' having count(*) > 1)
     or exists (select 1 from _bin b cross join jsonb_array_elements(b.meta) e
                 where (e->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i)
                 group by b.i, e->>'sn' having count(*) > 1) then
    raise exception 'poll_commit_batch: an inverter twice in one row' using errcode = '21000';
  end if;

  perform set_config('billing.guarded', 'on', true);

  -- 3. readings
  create temp table _brd on commit drop as
    select b.i, e.n, jsonb_populate_record(null::public.readings, e.v) as rw
      from _bin b cross join jsonb_array_elements(b.readings) with ordinality e (v, n)
     where (e.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i);
  delete from _brd where (rw).plant_id is null;
  create temp table _brw on commit drop as
    select distinct on ((d.rw).ts, (d.rw).sn) d.rw from _brd d
     order by (d.rw).ts, (d.rw).sn, case when (d.rw).ts = p_ts then -d.i else d.i end, d.n;
  perform 1 from public.readings r join _brw w on r.ts = (w.rw).ts and r.sn = (w.rw).sn
   where r.ts = p_ts order by r.ts, r.sn for update of r;
  delete from public.readings r using _brw w where r.ts = p_ts and r.ts = (w.rw).ts and r.sn = (w.rw).sn;
  insert into public.readings select (w.rw).* from _brw w order by (w.rw).ts, (w.rw).sn on conflict do nothing;

  -- 4. strings: used_strings, string_slots, unused inputs dropped (0061), then as readings
  create temp table _bst on commit drop as
    select b.i, e.n, jsonb_populate_record(null::public.strings, e.v) as rw
      from _bin b cross join jsonb_array_elements(b.strings) with ordinality e (v, n)
     where (e.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i);
  delete from _bst where (rw).plant_id is null;
  perform 1 from plants.meta_info m
   where m.sn in (select (t.rw).sn from _bst t
                  union select e->>'sn' from _bin b cross join jsonb_array_elements(b.meta) e)
   order by m.sn for no key update;
  -- poll_commit_v2 updates an inverter's string records only once its meta row exists: from the
  -- batch's start (avail 0), or from the object after the first one that sent its meta
  create temp table _bme on commit drop as
    select m.sn, 0 as avail from plants.meta_info m where m.sn in (select (t.rw).sn from _bst t);
  insert into _bme
  select e->>'sn', min(b.i) + 1 from _bin b cross join jsonb_array_elements(b.meta) e
   where (e->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i)
     and e->>'sn' in (select (t.rw).sn from _bst t) and e->>'sn' not in (select sn from _bme)
   group by e->>'sn';
  -- meta (only plants written), the last object winning, in sn order; ord and status: the last sent
  perform public.meta_upsert(coalesce((
    select jsonb_agg(m.v || jsonb_build_object('ord', m.ord, 'status', m.status) order by m.sn)
      from (select distinct on (q.v->>'sn') q.v->>'sn' as sn, q.v,
                   (select r.v->>'ord' from (select b2.i, e2.n, e2.v from _bin b2 cross join jsonb_array_elements(b2.meta) with ordinality e2 (v, n)) r
                     where r.v->>'sn' = q.v->>'sn' and nullif(r.v->>'ord', '') is not null
                       and (r.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = r.i)
                     order by r.i desc, r.n desc limit 1) as ord,
                   (select r.v->>'status' from (select b2.i, e2.n, e2.v from _bin b2 cross join jsonb_array_elements(b2.meta) with ordinality e2 (v, n)) r
                     where r.v->>'sn' = q.v->>'sn' and nullif(r.v->>'status', '') is not null
                       and (r.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = r.i)
                     order by r.i desc, r.n desc limit 1) as status
              from (select b.i, e.n, e.v from _bin b cross join jsonb_array_elements(b.meta) with ordinality e (v, n)
                     where (e.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i)) q
             order by q.v->>'sn', q.i desc, q.n desc) m), '[]'));
  -- the input count of the last object that sent the inverter once its meta row existed
  update private.meta m set string_slots = c.n
    from (select distinct on (q.sn) q.sn, q.n from
            (select (t.rw).sn as sn, t.i, count(*)::int as n from _bst t
              where t.i >= (select x.avail from _bme x where x.sn = (t.rw).sn) group by 1, 2) q
           order by q.sn, q.i desc) c
   where m.sn = c.sn and m.string_slots is distinct from c.n;
  -- unused inputs dropped as poll_commit_v2 does object by object: a dead input stays only when
  -- used before the batch, or live in this or an earlier object once the meta row existed
  delete from _bst t
   where not private.string_live((t.rw).volt_v, (t.rw).current_a, (t.rw).power_w, (t.rw).today_kwh)
     and not exists (select 1 from plants.meta_info m join _bme x on x.sn = m.sn
                      where m.sn = (t.rw).sn and x.avail <= t.i
                        and ((t.rw).no = any (m.used_strings)
                             or exists (select 1 from _bst t2
                                         where (t2.rw).sn = (t.rw).sn and (t2.rw).no = (t.rw).no
                                           and t2.i between x.avail and t.i
                                           and private.string_live((t2.rw).volt_v, (t2.rw).current_a,
                                                                   (t2.rw).power_w, (t2.rw).today_kwh))));
  update private.meta m
     set used_strings = (select array_agg(distinct y order by y)
                           from unnest(m.used_strings || array(
                             select (t.rw).no from _bst t
                              where (t.rw).sn = m.sn and t.i >= (select x.avail from _bme x where x.sn = m.sn)
                                and private.string_live((t.rw).volt_v, (t.rw).current_a, (t.rw).power_w, (t.rw).today_kwh))) y)
   where exists (select 1 from _bst t
                  where (t.rw).sn = m.sn and not ((t.rw).no = any (m.used_strings))
                    and t.i >= (select x.avail from _bme x where x.sn = m.sn)
                    and private.string_live((t.rw).volt_v, (t.rw).current_a, (t.rw).power_w, (t.rw).today_kwh));
  create temp table _bsw on commit drop as
    select distinct on ((d.rw).ts, (d.rw).sn, (d.rw).no) d.rw from _bst d
     order by (d.rw).ts, (d.rw).sn, (d.rw).no, case when (d.rw).ts = p_ts then -d.i else d.i end, d.n;
  perform 1 from public.strings s join _bsw w on s.ts = (w.rw).ts and s.sn = (w.rw).sn and s.no = (w.rw).no
   where s.ts = p_ts order by s.ts, s.sn, s.no for update of s;
  delete from public.strings s using _bsw w
   where s.ts = p_ts and s.ts = (w.rw).ts and s.sn = (w.rw).sn and s.no = (w.rw).no;
  insert into public.strings select (w.rw).* from _bsw w order by (w.rw).ts, (w.rw).sn, (w.rw).no on conflict do nothing;

  -- 5. plant minutes: gaps from max(ts) before the batch, first write wins
  create temp table _bag on commit drop as
    select b.i, e.n, (e.v->>'plant_id')::bigint as plant,
           nullif(e.v->>'pv_w',   '')::int as pv_w,
           nullif(e.v->>'load_w', '')::int as load_w,
           nullif(e.v->>'batt_w', '')::int as batt_w,
           nullif(e.v->>'grid_w', '')::int as grid_w,
           nullif(e.v->>'soc',    '')::int as soc,
           coalesce((e.v->>'partial')::boolean, false) as partial
      from _bin b cross join jsonb_array_elements(b.agg) with ordinality e (v, n)
     where e.v->>'plant_id' is not null
       and (e.v->>'plant_id')::bigint in (select o.plant from _bok o where o.i = b.i);
  create temp table _bgap on commit drop as
    select p.plant, p.first_i, (select max(a.ts) from public.agg_minute a where a.plant_id = p.plant) as prev
      from (select g.plant, min(g.i) as first_i from _bag g group by g.plant) p;
  insert into private.gaps (plant_id, from_ts, to_ts)
  select g.plant, g.prev, p_ts from _bgap g where g.prev is not null and p_ts - g.prev > 90 order by g.plant
  on conflict (plant_id, from_ts) do nothing;
  -- SOLAR-378: a hole over 10 minutes is refilled by History, each local day it touches (SOLAR-686 H11)
  perform history.gap_queue(g.plant, g.prev, p_ts) from _bgap g where g.prev is not null and p_ts - g.prev > 600 order by g.plant;
  insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
  select distinct on (g.plant) g.plant, p_ts, g.pv_w, g.load_w, g.batt_w, g.grid_w, g.soc,
         case when g.partial then 'poller_partial' else 'poller' end
    from _bag g order by g.plant, g.i, g.n
  on conflict (plant_id, ts) do nothing;

  -- 6. inverters (all), the last object winning, in sn order
  perform public.inverters_seed(coalesce((
    select jsonb_agg(m.v order by m.sn)
      from (select distinct on (e.v->>'sn') e.v->>'sn' as sn, e.v
              from _bin b cross join jsonb_array_elements(b.inverters) with ordinality e (v, n)
             order by e.v->>'sn', b.i desc, e.n desc) m), '[]'));

  -- 7. the other logins that see these plants were served this minute too
  perform plants.logins_served(array(select g.plant from _bag g), accts);
  perform set_config('billing.guarded', 'off', true);

  -- 8. new readings on a deleted plant: it has history again (0246)
  update billing.plant_facts bp set history_purged_at = null
   where bp.history_purged_at is not null
     and exists (select 1 from _bok o join _bin b on b.i = o.i
                  where o.plant = bp.plant
                    and (exists (select 1 from jsonb_array_elements(b.readings) e where (e->>'plant_id')::bigint = bp.plant)
                         or exists (select 1 from jsonb_array_elements(b.agg) e where (e->>'plant_id')::bigint = bp.plant)));

  return query
  select b.i, b.account, jsonb_build_object(
           'readings', (select count(*) from _brd d where d.i = b.i)::int,
           'strings',  (select count(*) from _bst t where t.i = b.i)::int,
           'plants',   to_jsonb(array(select g.plant from _bag g where g.i = b.i order by g.n)),
           'gaps',     to_jsonb(array(select g.plant from _bgap g
                                       where g.first_i = b.i and g.prev is not null and p_ts - g.prev > 90
                                       order by (select min(a.n) from _bag a where a.i = b.i and a.plant = g.plant))),
           'refused',  to_jsonb(array(select k::bigint from jsonb_object_keys(b.versions) k
                                       where k::bigint not in (select o.plant from _bok o where o.i = b.i) order by 1)))
    from _bin b order by b.i;
end $function$;

CREATE OR REPLACE FUNCTION public.poll_commit(p_account uuid, p_ts bigint, p_readings jsonb, p_strings jsonb, p_agg jsonb, p_meta jsonb, p_inverters jsonb, p_access text, p_expires bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare
  n_readings int := 0;
  n_strings  int := 0;
  gaps       bigint[] := '{}';
  plant_list     bigint[] := '{}';
  a          record;
  prev_ts    bigint;
begin
  if to_regclass('pg_temp._rd') is not null then drop table _rd; end if;
  if to_regclass('pg_temp._st') is not null then drop table _st; end if;

  create temp table _rd on commit drop as
    select * from jsonb_populate_recordset(null::public.readings, coalesce(p_readings, '[]'::jsonb))
     where plant_id is not null;
  delete from public.readings r using _rd where r.ts = p_ts and r.ts = _rd.ts and r.sn = _rd.sn;
  insert into public.readings select * from _rd on conflict do nothing;
  select count(*) into n_readings from _rd;

  create temp table _st on commit drop as
    select * from jsonb_populate_recordset(null::public.strings, coalesce(p_strings, '[]'::jsonb))
     where plant_id is not null;
  -- Remember every input that has ever produced, and how many inputs each inverter
  -- reports (0061). An input that has never produced is not wired to anything: its
  -- all-zero row is dropped rather than stored every minute. An input that has
  -- produced keeps every row, zeros included, so a string that dies still shows.
  update private.meta m
     set used_strings = (select array_agg(distinct x order by x)
                           from unnest(m.used_strings || array(
                             select t.no from _st t
                              where t.sn = m.sn and private.string_live(t.volt_v, t.current_a, t.power_w, t.today_kwh))) x)
   where exists (select 1 from _st t
                  where t.sn = m.sn and not (t.no = any(m.used_strings))
                    and private.string_live(t.volt_v, t.current_a, t.power_w, t.today_kwh));
  update private.meta m set string_slots = c.n
    from (select sn, count(*)::int as n from _st group by sn) c
   where m.sn = c.sn and m.string_slots is distinct from c.n;
  delete from _st t
   where not private.string_live(t.volt_v, t.current_a, t.power_w, t.today_kwh)
     and not exists (select 1 from plants.meta_info m where m.sn = t.sn and t.no = any(m.used_strings));
  delete from public.strings s using _st where s.ts = p_ts and s.ts = _st.ts and s.sn = _st.sn and s.no = _st.no;
  insert into public.strings select * from _st on conflict do nothing;
  select count(*) into n_strings from _st;

  for a in
    select (r->>'plant_id')::bigint as plant_id,
           nullif(r->>'pv_w',   '')::int as pv_w,
           nullif(r->>'load_w', '')::int as load_w,
           nullif(r->>'batt_w', '')::int as batt_w,
           nullif(r->>'grid_w', '')::int as grid_w,
           nullif(r->>'soc',    '')::int as soc,
           coalesce((r->>'partial')::boolean, false) as partial
      from jsonb_array_elements(coalesce(p_agg, '[]'::jsonb)) r
     where r->>'plant_id' is not null
  loop
    plant_list := plant_list || a.plant_id;

    select max(ts) into prev_ts from public.agg_minute where plant_id = a.plant_id;
    if prev_ts is not null and p_ts - prev_ts > 90 then
      insert into private.gaps (plant_id, from_ts, to_ts) values (a.plant_id, prev_ts, p_ts)
      on conflict (plant_id, from_ts) do nothing;
      gaps := gaps || a.plant_id;
      -- SOLAR-378: a hole over 10 minutes is refilled by History (SOLAR-686 H11).
      if p_ts - prev_ts > 600 then
        perform history.gap_queue(a.plant_id, prev_ts, p_ts);
      end if;
    end if;

    insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
    values (a.plant_id, p_ts, a.pv_w, a.load_w, a.batt_w, a.grid_w, a.soc,
            case when a.partial then 'poller_partial' else 'poller' end)
    on conflict (plant_id, ts) do nothing;
  end loop;

  perform public.meta_upsert(coalesce(p_meta, '[]'::jsonb));
  perform public.inverters_seed(coalesce(p_inverters, '[]'::jsonb));
  -- the newer token wins: a shard that started on an older token (it slept up to 20 s)
  -- must not overwrite one renewed since (SOLAR-649)
  perform plants.tokens_saved(jsonb_build_array(jsonb_build_object('account', p_account, 'access', p_access, 'expires', p_expires)));
  -- The other logins that can see these plant_list were served this minute too.
  perform plants.logins_served(plant_list, array[p_account]);

  return jsonb_build_object(
    'readings', n_readings,
    'strings',  n_strings,
    'plants',   to_jsonb(plant_list),
    'gaps',     to_jsonb(gaps));
end;
$function$;

CREATE OR REPLACE FUNCTION public.q_missing_minutes_day(p_plant bigint, p_day date)
 RETURNS TABLE(ts bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with b as (
    select public.day_start_epoch_tz(p_day, public.plant_tz(p_plant)) as lo,
           least(public.day_start_epoch_tz(p_day + 1, public.plant_tz(p_plant)),
                 extract(epoch from now())::bigint - 600) as hi)
  select g from b, generate_series(b.lo, b.hi - 60, 60) g
   where b.hi > b.lo
     and not exists (select 1 from public.agg_minute a where a.plant_id = p_plant and a.ts = g
                                                  and a.source <> 'poller_partial')
   order by g
$function$;

CREATE OR REPLACE FUNCTION plants.plant_listed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare uid uuid;
begin
  if tg_table_name = 'claims' then
    uid := (select a.user_id from billing.accounts a where a.id = new.account);
  else
    uid := (select l.user_id from plants.logins l where l.id = new.login and l.kind = 'login');
  end if;
  -- the plant's history is ready already: this account's one mail (SOLAR-686 H17)
  if uid is not null and exists (select 1 from public.plant_config c where c.plant_id = new.plant) and history.ready(new.plant) then
    insert into public.email_queue (user_id, plant_id, kind, key, priority)
    values (uid, new.plant, 'history', 'history:' || new.plant, 1)
    on conflict do nothing;
  end if;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.api_overview(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  v_plant bigint := public.my_plant(p_plant);
  -- a variable, not now() in the query, so the planner cuts to the last 2 days
  v_floor bigint := extract(epoch from now())::bigint - 2 * 86400;
  v_ts    bigint;
  v_lo    bigint;  -- start of v_ts's local day: day counters count from here
  v_from  bigint;  -- the inverter list's window: the 2-day floor, or v_ts's day if older
  v_glo   bigint;  -- start of the plant's local today (not v_ts's day): grid_today counts from here
  v_out   jsonb;
begin
  select max(ts) into v_ts from public.readings where plant_id = v_plant and ts > v_floor;
  if v_ts is null then
    -- nothing in 2 days (outage, or a plant that stopped): look further back
    select max(ts) into v_ts from public.readings where plant_id = v_plant;
  end if;
  v_lo := public.day_start_epoch_tz((to_timestamp(v_ts) at time zone public.plant_tz(v_plant))::date, public.plant_tz(v_plant));
  v_from := least(v_floor, v_lo);
  -- a variable, not a CTE join: joined, the bound is unknown at plan time and the
  -- scan ran 18 ms instead of 2 (measured 2026-11-24)
  v_glo := public.day_start_epoch_tz(public.today_tz(public.plant_tz(v_plant)), public.plant_tz(v_plant));

  with pl as (select v_plant as id),
  cfg as (select * from public.plant_cfg(v_plant)),
  -- each known inverter's own last row in the window (SOLAR-555). An inverter the poller
  -- left out of the newest minute (SOLAR-296) keeps its day totals and its readAt; only
  -- the live figures below are limited to rows at v_ts. A row from before v_lo (silent
  -- since yesterday) lists the inverter but adds 0 to today's counters. Bounds are
  -- variables, not a join to a CTE, so each probe opens only the window's partitions
  -- (sn_ts index).
  r as (
    select x.*, x.ts >= v_lo as is_today from plants.inverter_info i
      cross join lateral (select rd.* from public.readings rd
                           where rd.sn = i.sn and rd.plant_id = v_plant and rd.ts >= v_from and rd.ts <= v_ts
                           order by rd.ts desc limit 1) x
     where i.plant_id = v_plant
  ),
  st as (
    select s.sn, jsonb_agg(jsonb_build_object('id', null, 'no', s.no, 'power', s.power_w, 'voltage', s.volt_v, 'current', s.current_a,
             'today', case when r.is_today then s.today_kwh else 0 end) order by s.no) as strings
      from r join public.strings s on s.plant_id = v_plant and s.sn = r.sn and s.ts = r.ts
     where s.ts >= v_from and s.ts <= v_ts
     group by s.sn
  ),
  inv as (
    select r.sn,
           jsonb_build_object(
             'sn', r.sn, 'alias', coalesce(m.alias, r.sn), 'model', m.model, 'status', r.status, 'gsn', m.gsn,
             'soft', m.soft_ver, 'hmi', m.hmi_ver, 'commType', m.comm_type,
             -- when the inverter took this reading, epoch seconds; a 5-minute logger can be minutes behind (0075)
             -- guarded: one malformed device_time must not take the whole snapshot down with a cast error
             'readAt', case when r.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                         then extract(epoch from (r.device_time::timestamp at time zone public.plant_tz(v_plant)))::bigint end,
             'pv', jsonb_build_object('power', round(r.pv_w), 'today', case when r.is_today then r.pv_today_kwh else 0 end, 'total', r.pv_total_kwh, 'strings', coalesce(st.strings, '[]'::jsonb),
                     -- inputs the inverter reports, wired or not (0061); the page shows the rest as unused
                     'stringSlots', m.string_slots),
             'battery', jsonb_build_object(
               'power', round(abs(r.batt_w)), 'signedPower', round(r.batt_w),
               'status', case when r.batt_w > 5 then 'charging' when r.batt_w < -5 then 'discharging' else 'idle' end,
               'soc', r.batt_soc, 'voltage', r.batt_voltage_v, 'current', r.batt_current_a, 'temperature', r.batt_temp_c,
               'capacity', m.capacity_ah, 'numberOfBatteries', m.number_of_batteries,
               'todayCharged', case when r.is_today then r.batt_chg_today_kwh else 0 end,
               'todayDischarged', case when r.is_today then r.batt_dischg_today_kwh else 0 end,
               'totalCharged', r.batt_chg_total_kwh, 'totalDischarged', r.batt_dischg_total_kwh,
               -- second bank (the API's *2 fields), only when the firmware reports one (0042)
               'bank2', case when r.batt2_soc is not null then jsonb_build_object(
                 'soc', r.batt2_soc, 'voltage', r.batt2_voltage_v, 'current', r.batt2_current_a,
                 'power', r.batt2_power_w, 'temperature', r.batt2_temp_c) end),
             'grid', jsonb_build_object(
               'power', round(r.grid_w), 'direction', case when r.grid_w >= 0 then 'importing' else 'exporting' end,
               'todayImport', case when r.is_today then r.grid_import_today_kwh else 0 end,
               'todayExport', case when r.is_today then r.grid_export_today_kwh else 0 end,
               'totalImport', r.grid_import_total_kwh, 'totalExport', r.grid_export_total_kwh,
               'frequency', r.grid_freq_hz, 'powerFactor', r.grid_pf,
               'voltage', r.grid_volt_v, 'relay', r.grid_relay_status,
               -- one entry per phase this inverter reports (L1 [, L2, L3])
               'voltages', (select jsonb_agg(v) from unnest(array[r.grid_volt_v, r.grid_volt_l2_v, r.grid_volt_l3_v]) v where v is not null)),
             'load', jsonb_build_object('power', round(r.load_w), 'today', case when r.is_today then r.load_today_kwh else 0 end, 'total', r.load_total_kwh, 'frequency', r.load_freq_hz),
             'output', jsonb_build_object('power', round(r.output_w), 'voltage', r.output_volt_v, 'frequency', r.output_freq_hz,
               'voltages', (select jsonb_agg(v) from unnest(array[r.output_volt_v, r.output_volt_l2_v, r.output_volt_l3_v]) v where v is not null))) as snap,
           r.ts, r.pv_w, r.load_w, r.grid_w, r.batt_w, r.batt_soc,
           case when r.is_today then r.pv_today_kwh else 0 end as pv_today_kwh,
           case when r.is_today then r.grid_import_today_kwh else 0 end as grid_import_today_kwh,
           case when r.is_today then r.grid_export_today_kwh else 0 end as grid_export_today_kwh,
           r.grid_volt_v, r.grid_volt_l2_v, r.grid_volt_l3_v,
           coalesce(m.ord, 9999) as ord
      from r left join plants.meta_info m on m.sn = r.sn left join st on st.sn = r.sn
  ),
  -- live figures from the inverters in the newest minute only; day counters from every row
  totals as (
    select sum(round(pv_w)) filter (where ts = v_ts) as pv, sum(round(load_w)) filter (where ts = v_ts) as load,
           sum(round(grid_w)) filter (where ts = v_ts) as grid, sum(round(batt_w)) filter (where ts = v_ts) as batt,
           -- one shared pack: every inverter reads the same BMS, so take the first (master) rather than averaging copies
           case when (select battery_banks from cfg) = 'shared'
                then (select i.batt_soc from inv i where i.batt_soc > 0 and i.ts = v_ts order by i.ord, i.sn limit 1)
                else avg(batt_soc) filter (where batt_soc > 0 and ts = v_ts) end as soc,
           sum(pv_today_kwh) as today_pv, sum(grid_import_today_kwh) as today_imp, sum(grid_export_today_kwh) as today_exp,
           -- a phase that has dropped while another is live (three-phase only)
           bool_or(public.grid_live(grid_volt_v) and not public.grid_live(least(coalesce(grid_volt_l2_v, 999), coalesce(grid_volt_l3_v, 999)))) filter (where ts = v_ts) as phase_down
      from inv
  ),
  -- q_grid_present's rule on the rows already in r (same plant, same ts); calling
  -- it planned readings again with every partition
  gv as (select grid_volt_v, device_time from r where grid_volt_v is not null and ts = v_ts),
  gp as (
    select case when not exists (select 1 from gv) then null
                else (select bool_or(public.grid_live(v.grid_volt_v)) from gv v
                       where v.device_time is not distinct from (select max(device_time) from gv)) end as present
  ),
  -- q_day_agg's day and 5-minute blocks, grid only (0260)
  grid_today as (
    select coalesce(sum(case when grid_w > 0 then grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           coalesce(sum(case when grid_w < 0 then -grid_w * (5.0/60) / 1000 else 0 end), 0) as exp,
           count(*) as n
      from (select round(avg(a.grid_w)::numeric) as grid_w
              from public.agg_minute a
             where a.plant_id = v_plant and a.ts >= v_glo and a.ts < v_glo + 86400
             group by (a.ts - v_glo) / 300) b
  ),
  plant as (select pu.plant_id as id, pu.plant_name as name from plants.user_plants pu
             where pu.plant_id = v_plant and pu.user_id = auth.uid() limit 1)
  select jsonb_build_object(
    'generatedAt', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    -- the poller's last minute for this plant, as api_health answers it
    'lastTs', (select max(ts) from public.agg_minute where plant_id = v_plant),
    'plant', jsonb_build_object('id', (select id from plant), 'name', coalesce((select name from plant), 'My plant')),
    'totals', jsonb_build_object(
      'pv', t.pv, 'load', t.load, 'grid', t.grid,
      'gridDirection', case when t.grid >= 0 then 'importing' else 'exporting' end,
      'batteryPower', abs(t.batt),
      'batteryDirection', case when abs(t.batt) <= 5 then 'idle' when t.batt > 0 then 'charging' else 'discharging' end,
      'soc', case when t.soc is null then null else round(t.soc) end,
      'todayPv', round(t.today_pv::numeric, 2),
      'todayGridImport', round((case when g.n > 5 then g.imp else t.today_imp end)::numeric, 2),
      'todayGridExport', round((case when g.n > 5 then g.exp else t.today_exp end)::numeric, 2),
      'gridPresent', (select present from gp),
      'phaseDown', coalesce(t.phase_down, false)),
    'config', jsonb_build_object(
      'battCapacity', c.battery_kwh, 'reserve', c.battery_reserve_pct,
      'currency', c.currency, 'timezone', plants.tz(v_plant), 'tariffImport', c.tariff_import, 'tariffExport', c.tariff_export,
      'systemKwp', c.system_kwp, 'panelTilt', c.panel_tilt, 'panelAzimuth', c.panel_azimuth,
      'geometrySource', c.geometry_source,
      'batteryBanks', c.battery_banks, 'hasBattery', c.has_battery, 'hasGrid', c.has_grid, 'featuresSource', c.features_source,
      'battPositiveMeans', c.batt_positive_means, 'battSignSource', c.batt_sign_source,
      'forecastAvailable', v_plant = public.calibration_plant()),
    'inverters', coalesce((select jsonb_agg(snap order by ord, sn) from inv), '[]'::jsonb),
    -- History's progress (SOLAR-686 H16)
    'sync', history.progress(v_plant))
    into v_out
  from totals t, grid_today g, cfg c;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION public.api_plant_states()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  -- a variable, not now() in the query, so the planner cuts to the last 2 days
  v_floor bigint := extract(epoch from now())::bigint - 2 * 86400;
  v_out   jsonb := '[]'::jsonb;
  p       record;
  v_ts    bigint;
  v_lo    bigint;
  v_from  bigint;
  v_total int;
  v_on    int;
  v_sync  jsonb;
begin
  for p in select pu.plant_id from plants.user_plants pu
            where pu.user_id = auth.uid() and pu.plant_id in (select public.my_plant_ids())
            order by pu.linked_at, pu.plant_id loop
    select max(ts) into v_ts from public.readings where plant_id = p.plant_id and ts > v_floor;
    if v_ts is null then
      select max(ts) into v_ts from public.readings where plant_id = p.plant_id;
    end if;
    -- known inverters with a row in the last 2 days, or on v_ts's day when that is older
    -- (SOLAR-555); online = in the newest minute and flagged online. One sn_ts probe per
    -- inverter.
    v_lo := public.day_start_epoch_tz((to_timestamp(v_ts) at time zone public.plant_tz(p.plant_id))::date, public.plant_tz(p.plant_id));
    v_from := least(v_floor, v_lo);
    select count(*), count(*) filter (where x.ts = v_ts and x.status::text in ('1', 'online', 'true'))
      into v_total, v_on
      from plants.inverter_info i
      cross join lateral (select rd.ts, rd.status from public.readings rd
                           where rd.sn = i.sn and rd.plant_id = p.plant_id and rd.ts >= v_from and rd.ts <= v_ts
                           order by rd.ts desc limit 1) x
     where i.plant_id = p.plant_id;

    v_sync := history.progress(p.plant_id);                             -- SOLAR-686 H16

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', p.plant_id, 'lastTs', v_ts, 'inverters', v_total, 'online', v_on, 'sync', v_sync));
  end loop;
  return v_out;
end $function$;

CREATE OR REPLACE FUNCTION private.schedule_jobs()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'pg_temp'
AS $function$
declare j record;
begin
  -- pg_cron keys a job by name and user: run as anyone else, every job would be made twice
  if current_user <> 'postgres' then
    raise exception 'run private.schedule_jobs() as postgres, not %', current_user using errcode = '42501';
  end if;
  for j in select * from (values
    ('agg-minute-rollup',    '40 4 * * *',         $c$select private.agg_minute_rollup(31)$c$),
    ('alerts',               '* * * * *',          $c$select private.alerts_minute()$c$),
    ('plant-check',          '* * * * *',          $c$select private.plant_checks()$c$),
    ('plant-sync',           '* * * * *',          $c$select private.call_fn('plant-jobs', '{"task":"sync"}', 55000)$c$),
    ('temps',                '* * * * *',          $c$select private.call_fn('history', '{"task":"temps"}', 55000)$c$),
    ('billing-delete',       '*/5 * * * *',        $c$select billing.delete_due()$c$),
    ('billing-run',          '*/5 4-5 * * *',      $c$select private.call_fn('billing/run', '{}', 120000)$c$),
    ('ensure-partitions',    '0 3 * * *',          $c$select private.ensure_partitions()$c$),
    ('history',              '* * * * *',          $c$select private.call_fn('history', jsonb_build_object('task', 'queue', 'shard', s.shard, 'shards', s.shards), 60000) from history.shards() s$c$),
    ('history-check',        '5 4,10,16,22 * * *', $c$select private.call_fn('history', '{"task":"check"}', 60000)$c$),
    ('history-totals',       '15 2 * * *',         $c$select history.totals_queue()$c$),
    ('history-trim',         '20 3 * * *',         $c$select private.call_fn('history', '{"task":"trim"}', 150000)$c$),
    ('grid-off',             '10 4 * * *',         $c$select private.grid_off_update_all()$c$),
    ('history-delete',       '* * * * *',          $c$call private.history_delete_run()$c$),
    ('history-delete-slow',  '*/15 * * * *',       $c$call private.history_delete_check()$c$),
    ('job-check',            '2-59/5 * * * *',     $c$select private.call_fn('job-check', '{}', 30000)$c$),
    ('notify-email',         '* * * * *',          $c$select private.call_fn('notify-email', '{}', 55000)$c$),
    ('notify-push',          '* * * * *',          $c$select private.call_fn('notify-push', '{}', 55000)$c$),
    ('purge-cron-log',       '45 4 * * *',         $c$delete from cron.job_run_details where end_time < now() - make_interval(days => 7)$c$),
    ('rollup-old-days',      '*/5 5-7 * * *',      $c$call private.rollup_old_days(31)$c$),
    ('reader',               '* * * * *',          $c$select private.call_fn('poll', jsonb_build_object('shard', s.shard, 'shards', s.shards, 'delay_ms', s.delay_ms), 55000) from private.poll_shards() s$c$)
  ) t(name, sched, cmd) loop
    perform cron.schedule(j.name, j.sched, j.cmd);   -- by name: an existing job is updated in place
  end loop;
  -- the names before SOLAR-681 R16: gone, so no job runs twice
  perform cron.unschedule(jobname) from cron.job where jobname in ('sunsynk-poll', 'sunsynk-recover', 'sunsynk-plant-energy');
  -- the two old history engines (SOLAR-686 H1, H23): by name
  perform cron.unschedule(jobname) from cron.job
   where jobname in ('recover', 'billing-history', 'first-load-continue', 'plant-energy');
end $function$;

CREATE OR REPLACE FUNCTION plants.purge(p_plant bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n int; out jsonb := '{}';
begin
  perform history.stop(p_plant, 'deleted');                                -- SOLAR-686 H15
  delete from public.plant_config   where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_config', n);
  delete from public.config_changes where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('config_changes', n);
  delete from private.meta          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('meta', n);
  delete from private.inverters     where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverters', n);
  return out;
end $function$;

-- the old engines' functions (H24); the old tables and columns go next release (H23)
drop function public.plant_history_loading(bigint);
drop function public.plant_bookmarks_clear(bigint[]);
drop function private.first_load_continue();
drop function public.q_missing_minutes(bigint, date);
drop function billing.history_take(timestamp with time zone);
drop function billing.history_step(bigint, date, boolean, boolean, timestamp with time zone, uuid);
drop function billing.history_renew(bigint, uuid, timestamp with time zone);

-- ---------------------------------------------------------------------------
-- the copy (H23): whatever the old engines hold at this moment, into the new queue; then the
-- compare against the old tables themselves, which raises unless every bookmark, fetch, refill
-- and back-off has its new row. Writers of the old bookmarks wait on the locks below; the
-- functions that wrote them are replaced above, in this transaction.

-- the old engines must have stopped first (the release's pre-step, DEPLOY.md): their cron jobs
-- unscheduled and their last call over 3 minutes ago, so nothing moves an old bookmark after the copy.
-- A hosted project only; a local stack built from migrations has no old calls in flight.
do $$
begin
  if coalesce((select v.decrypted_secret from vault.decrypted_secrets v where v.name = 'functions_url'), '') like '%.supabase.co%' and exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname in ('recover', 'billing-history', 'first-load-continue', 'plant-energy')) then
      raise exception 'SOLAR-686: unschedule recover, billing-history, first-load-continue and plant-energy, wait 3 minutes, then release (DEPLOY.md)';
    end if;
    if exists (select 1 from cron.job_run_details r where r.start_time > now() - interval '3 minutes'
                 and (r.command ilike '%recover%' or r.command ilike '%sync-plant-energy%' or r.command ilike '%first_load_continue%')) then
      raise exception 'SOLAR-686: an old history call ran in the last 3 minutes: wait, then release again';
    end if;
  end if;
  if coalesce((select v.decrypted_secret from vault.decrypted_secrets v where v.name = 'functions_url'), '') like '%.supabase.co%' and exists (select 1 from private.recover_kicks k where k.at > now() - interval '3 minutes') then
    raise exception 'SOLAR-686: a link kicked recover in the last 3 minutes: wait, then release again';
  end if;
end $$;

lock table public.plant_config, billing.history_fetches, billing.history_lanes, private.refill_queue in exclusive mode;

create temp table _seat on commit drop as
  select distinct s.plant, s.account from billing.seats s where s.closed_at is null;
create temp table _fetch on commit drop as
  select distinct on (h.account, h.plant) h.* from billing.history_fetches h
   where h.status in ('queued', 'running') order by h.account, h.plant, h.id desc;

-- one import per plant with a first load still walking or a seat-switch fetch open, for the
-- accounts that hold it: a fetch's account keeps its pace, a first load's accounts go at once
insert into history.imports (plant, reason, requested_at, started_at, next_at, floor_day, top_day)
select x.plant, case when bool_or(x.bf) then 'link' else 'switch' end, min(x.requested_at), min(x.started_at),
       min(x.next_at), min(x.floor_day), (now() at time zone plants.tz(x.plant))::date - 1
  from (select c.plant_id as plant, true as bf, now() as requested_at, now() as started_at, now() as next_at, c.backfill_next as floor_day
          from public.plant_config c where c.backfill_next is not null and exists (select 1 from _seat s where s.plant = c.plant_id)
        union all
        select f.plant, false, f.requested_at, f.started_at, coalesce(f.next_step_at, f.requested_at),
               coalesce(f.day_floor, (now() at time zone plants.tz(f.plant))::date - 60)
          from _fetch f) x
 group by x.plant;
insert into history.import_accounts (import, account, reason, pace_s, fetch_no, requested_at)
select distinct on (i.id, y.account) i.id, y.account, y.reason, y.pace_s, y.fetch_no, y.requested_at
  from history.imports i
  join (select f.plant, f.account, 'switch' as reason, f.target_s as pace_s, f.fetch_no, f.requested_at, 0 as o from _fetch f
        union all
        select c.plant_id, s.account, 'link', 0, 0, now(), 1 from public.plant_config c join _seat s on s.plant = c.plant_id
         where c.backfill_next is not null) y on y.plant = i.plant
 order by i.id, y.account, y.o;
-- the days still to walk: a first load's backfill_next..backfill_until; a fetch's floor..day_next
-- (all 60 days for one not started); a retry count stays on the day it was for
insert into history.days (plant, import, day, kind, why, tries, due_at)
select i.plant, i.id, g.day, 'minutes', 'import', max(g.tries), now()
  from history.imports i
  join (select c.plant_id as plant, d::date as day,
               case when d::date = coalesce(c.backfill_until, c.backfill_next) then coalesce(c.backfill_tries, 0) else 0 end as tries
          from public.plant_config c, generate_series(c.backfill_next, coalesce(c.backfill_until, c.backfill_next), interval '1 day') d
         where c.backfill_next is not null
        union all
        select f.plant, d::date, case when d::date = f.day_next then f.tries else 0 end
          from _fetch f,
               generate_series(coalesce(f.day_floor, (now() at time zone plants.tz(f.plant))::date - 60),
                               coalesce(f.day_next, (now() at time zone plants.tz(f.plant))::date - 1), interval '1 day') d) g
    on g.plant = i.plant
 group by i.plant, i.id, g.day;
-- temperatures behind (temp_next before today), for a plant someone holds: with its import, or on their own
insert into history.days (plant, import, day, kind, why, tries, due_at)
select c.plant_id, i.id, d::date, 'extras', case when i.id is null then 'check' else 'import' end,
       case when d::date = c.temp_next then coalesce(c.temp_tries, 0) else 0 end, now()
  from public.plant_config c
  left join history.imports i on i.plant = c.plant_id and i.status = 'open'
  cross join generate_series(greatest(c.temp_next, (now() at time zone plants.tz(c.plant_id))::date - 60),
                             (now() at time zone plants.tz(c.plant_id))::date - 1, interval '1 day') d
 where c.temp_next is not null and c.temp_next < (now() at time zone plants.tz(c.plant_id))::date
   and exists (select 1 from _seat s where s.plant = c.plant_id);
-- holes waiting for a refill: today and yesterday, unless an import day holds them
insert into history.days (plant, day, kind, why, due_at)
select q.plant_id, (now() at time zone plants.tz(q.plant_id))::date - g, 'minutes', 'gap', q.queued_at
  from private.refill_queue q, generate_series(0, 1) g
on conflict (plant, day, kind) where status = 'queued' do nothing;
insert into history.lanes (lane, backoff_s, backoff_until)
select l.lane, l.backoff_s, l.backoff_until from billing.history_lanes l where l.backoff_s > 0 or l.backoff_until > now();

-- the compare, against the old tables: each count is what has no new row; every one must be 0.
-- Bookmarks of plants nobody holds are not carried (nothing reads such a plant; a restart asks
-- again): their count is reported, not compared.
do $$
declare miss jsonb; left_out int;
begin
  select jsonb_build_object(
    'first_load_days', (select count(*) from public.plant_config c,
                          generate_series(c.backfill_next, coalesce(c.backfill_until, c.backfill_next), interval '1 day') d
                         where c.backfill_next is not null and exists (select 1 from _seat s where s.plant = c.plant_id)
                           and not exists (select 1 from history.days x join history.imports i on i.id = x.import and i.status = 'open'
                                            where x.plant = c.plant_id and x.day = d::date and x.kind = 'minutes' and x.status = 'queued')),
    'fetch_accounts', (select count(*) from _fetch f
                        where not exists (select 1 from history.import_accounts a join history.imports i on i.id = a.import
                                           where i.plant = f.plant and i.status = 'open' and a.account = f.account
                                             and a.pace_s = f.target_s and a.fetch_no = f.fetch_no)),
    'fetch_days', (select count(*) from _fetch f,
                     generate_series(coalesce(f.day_floor, (now() at time zone plants.tz(f.plant))::date - 60),
                                     coalesce(f.day_next, (now() at time zone plants.tz(f.plant))::date - 1), interval '1 day') d
                    where not exists (select 1 from history.days x where x.plant = f.plant and x.day = d::date
                                        and x.kind = 'minutes' and x.status = 'queued')),
    'retries', (select count(*) from _fetch f where f.tries > 0
                  and not exists (select 1 from history.days x where x.plant = f.plant and x.day = f.day_next and x.tries = f.tries))
             + (select count(*) from public.plant_config c where c.backfill_next is not null and coalesce(c.backfill_tries, 0) > 0
                  and exists (select 1 from _seat s where s.plant = c.plant_id)
                  and not exists (select 1 from history.days x where x.plant = c.plant_id and x.kind = 'minutes'
                                    and x.day = coalesce(c.backfill_until, c.backfill_next) and x.tries >= c.backfill_tries))
             + (select count(*) from public.plant_config c where c.temp_next < (now() at time zone plants.tz(c.plant_id))::date
                  and coalesce(c.temp_tries, 0) > 0 and exists (select 1 from _seat s where s.plant = c.plant_id)
                  and not exists (select 1 from history.days x where x.plant = c.plant_id and x.kind = 'extras'
                                    and x.day = c.temp_next and x.tries = c.temp_tries)),
    'temperature_days', (select count(*) from public.plant_config c,
                           generate_series(greatest(c.temp_next, (now() at time zone plants.tz(c.plant_id))::date - 60),
                                           (now() at time zone plants.tz(c.plant_id))::date - 1, interval '1 day') d
                          where c.temp_next is not null and c.temp_next < (now() at time zone plants.tz(c.plant_id))::date
                            and exists (select 1 from _seat s where s.plant = c.plant_id)
                            and not exists (select 1 from history.days x where x.plant = c.plant_id and x.day = d::date
                                              and x.kind = 'extras' and x.status = 'queued')),
    'refills', (select count(*) from private.refill_queue q
                 where not exists (select 1 from history.days x where x.plant = q.plant_id and x.kind = 'minutes' and x.status = 'queued'
                                     and x.day = (now() at time zone plants.tz(q.plant_id))::date)),
    'lanes', (select count(*) from billing.history_lanes l where (l.backoff_s > 0 or l.backoff_until > now())
               and not exists (select 1 from history.lanes n where n.lane = l.lane and n.backoff_s = l.backoff_s
                                 and n.backoff_until is not distinct from l.backoff_until)))
    into miss;
  select count(*) into left_out from public.plant_config c
   where (c.backfill_next is not null or c.temp_next < (now() at time zone plants.tz(c.plant_id))::date)
     and not exists (select 1 from _seat s where s.plant = c.plant_id);
  if exists (select 1 from jsonb_each_text(miss) e where e.value::int <> 0) then
    raise exception 'SOLAR-686 copy: differences %', miss;
  end if;
  raise notice 'SOLAR-686 copy: % day rows, % imports, % lanes; compare 0 (%); % plants nobody holds left out',
    (select count(*) from history.days), (select count(*) from history.imports), (select count(*) from history.lanes), miss, left_out;
end $$;

-- the old cron jobs off, the new ones on (H23): run as postgres
do $$ begin
  if current_user = 'postgres' and exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform private.schedule_jobs();
  end if;
end $$;

-- last: these lock plant_config and plants.logins until the commit, a moment from now
drop trigger email_on_history on public.plant_config;
drop function private.email_on_history();
drop function private.history_done(public.plant_config);
alter table plants.logins add column throttled_at timestamptz;

commit;
