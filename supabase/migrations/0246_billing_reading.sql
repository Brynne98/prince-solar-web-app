-- ============================================================================
-- 0246 — billing redesign phase 3: reading, deleting and history fetches follow
--        the new state (SOLAR-641).
--
-- Design: reports/billing-redesign-2026-11-22.md (v2 items 1, 6, 9, 11; Round 4;
-- "History fetch speed").
--
-- The switch. Nothing here changes what runs today until billing.switch_on()
-- (DEPLOY.md, "Billing switch-over"). Before it, poll_jobs_v2 answers with the old
-- poll_jobs and the guarded writes let everything through, so the new poll and
-- recover can ship before the switch without stopping the logger. switch_on()
-- records the switch, turns the old unpaid-delete and plant-wipe jobs off and the
-- delete job and the history queue on.
--
-- Reading
--   poll_jobs_v2   the plants whose plant_state says read_now, each through one
--                  working route of an account that reads it: an ok login that
--                  still lists the plant, else a share claim (the share login).
--                  Logins before claims, the earliest first. Carries the plant's
--                  version.
--   poll_commit_v2, q_insert_recovered_v2, q_insert_inverter_history_v2
--                  the writes. Each locks the plant rows (share) and writes only
--                  plants whose version is still the one the fetch started on and
--                  that are still read. A fetch that finishes after a switch or a
--                  delete writes nothing. New readings clear history_purged_at.
--   A login that breaks (private.sunsynk_accounts.status) is copied onto
--   billing.logins at once: no read, history kept.
--   login_seen     the poller's hourly plant list: new plants added, a plant
--                  missing twice an hour apart marked gone.
--
-- Deleting
--   delete_due(at) every 5 minutes: every plant not yet purged whose plant_state
--                  delete_at has come. Locks the plant (skips one being written),
--                  re-checks, skips it while an account that holds or is buying it
--                  has a payment try pending under 24 hours, deletes its readings
--                  (private.plant_readings_delete), records history_purged_at.
--
-- History fetches (billing.history_fetches)
--   A seat opened (set_chosen_plants, a purchase, an upgrade) or a plan restarted
--   after it ended asks for one fetch: one history_fetch account event per command,
--   one queue row per plant. Live reading starts at once; the queue runs beside it
--   (recover ?queue=1, every minute). One running fetch per inverter-cloud login
--   (lane); on the shared service login accounts take turns. A request for a plant
--   its account no longer reads is dropped. A 429 backs the lane off (1 min,
--   doubling, 1 h at most). Speed: the account's counted history_fetch events in the
--   last 7 days, this one included. Only an owner's switch counts (one per confirmed
--   switch, whatever the number of plants); the first choice after a login or claim is
--   linked, a checkout, an upgrade and a restart never do. Fetches 1-3 at normal speed; the 4th takes at least
--   20 min, each later one twice the one before, 24 h at most, spread evenly over
--   its days. The start is never delayed. No reset: an event drops out after 7 days.
--
-- Monitoring
--   job_heartbeats (delete, history, billing-run) and billing.alerts(at): tries
--   pending over 1 hour, failed refunds, emails waiting over 1 hour, plants with
--   history past their delete date, accounts with more than 6 switches in 7 days,
--   jobs gone quiet. job-check sends them to PostHog like its other checks.
--
-- Also: billing.winback_return, the "came back after the win-back email" event
-- read from the new tables (phase 2 dropped it).
-- ============================================================================

create table billing.switch_over (
  id          boolean primary key default true check (id),
  switched_at timestamptz not null
);

create function billing.is_live()
returns boolean language sql stable set search_path = billing, pg_temp as $$
  select exists (select 1 from billing.switch_over)
$$;

-- ---------------------------------------------------------------------------
-- Does this account read this plant now? Open seat, plan or week running, not over
-- its places, and an ok login or a claim that still reaches the plant.
-- ---------------------------------------------------------------------------
create function billing.reads_plant(p_account uuid, p_plant bigint, p_at timestamptz)
returns boolean language sql stable set search_path = billing, pg_temp as $$
  select exists (select 1 from billing.seats s where s.account = p_account and s.plant = p_plant
                    and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at))
     and coalesce((select st.state in ('trialing', 'active', 'past_due') and not st.must_choose
                     from billing.account_status(p_account, p_at) st), false)
     and billing.has_route(p_account, p_plant, true)
$$;

-- Does the account still hold the plant: an open seat while its plan or week runs.
-- A request whose account no longer holds the plant is dropped; one that holds it
-- but cannot reach it now (a broken login) waits.
create function billing.holds_plant(p_account uuid, p_plant bigint, p_at timestamptz)
returns boolean language sql stable set search_path = billing, pg_temp as $$
  select exists (select 1 from billing.seats s where s.account = p_account and s.plant = p_plant
                    and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at))
     and coalesce((select st.state in ('trialing', 'active', 'past_due')
                     from billing.account_status(p_account, p_at) st), false)
$$;

-- Every working route of every account that reads a plant. lane = the stored
-- inverter-cloud login (private.sunsynk_accounts id) the read goes through.
create function billing.reading_routes(p_at timestamptz)
returns table (plant bigint, account uuid, lane uuid, via_share boolean, since timestamptz)
language sql stable set search_path = billing, private, pg_temp as $$
  with seat as (
    select s.account, s.plant from billing.seats s
     where s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  ), live as (
    select x.account from (select distinct account from seat) x
     cross join lateral billing.account_status(x.account, p_at) st
     where st.state in ('trialing', 'active', 'past_due') and not st.must_choose
  )
  select se.plant, se.account, l.id, false, l.created_at
    from seat se join live using (account)
    join billing.logins l on l.account = se.account and l.status = 'ok'
    join billing.login_plants lp on lp.login = l.id and lp.plant = se.plant and lp.gone_at is null
    join private.sunsynk_accounts sa on sa.id = l.id and sa.status = 'active'
  union all
  select se.plant, se.account, sa.id, true, c.claimed_at
    from seat se join live using (account)
    join billing.plant_claims c on c.plant = se.plant and c.account = se.account
    join private.sunsynk_accounts sa on sa.kind = 'share' and sa.status = 'active'
$$;

-- The lane a history fetch for this account's plant runs through: its own ok login
-- first, else the share login when it holds a claim.
create function billing.fetch_lane(p_account uuid, p_plant bigint)
returns uuid language sql stable set search_path = billing, private, pg_temp as $$
  select coalesce(
    (select l.id from billing.logins l
       join billing.login_plants lp on lp.login = l.id and lp.plant = p_plant and lp.gone_at is null
       join private.sunsynk_accounts sa on sa.id = l.id and sa.status = 'active'
      where l.account = p_account and l.status = 'ok'
      order by l.created_at, l.id limit 1),
    (select sa.id from billing.plant_claims c
       join private.sunsynk_accounts sa on sa.kind = 'share' and sa.status = 'active'
      where c.account = p_account and c.plant = p_plant limit 1))
$$;

-- ---------------------------------------------------------------------------
-- poll_jobs_v2: 0205's poll_jobs columns plus plant_version.
-- ---------------------------------------------------------------------------
create or replace function public.poll_jobs_v2(p_shard int, p_shards int, p_account uuid default null,
                                               p_at timestamptz default now())
returns table (
  plant_id bigint, plant_name text, timezone text, batt_positive_means text,
  backfill_next text, backfill_until text, backfill_tries int,
  temp_next text, temp_tries int, has_grid boolean,
  account_id uuid, user_id uuid, sunsynk_username text, access_token text, access_expires_at bigint,
  plant_version bigint)
language plpgsql stable security definer set search_path = public, private, pg_temp
as $$
begin
  if not billing.is_live() then
    return query select j.*, null::bigint from public.poll_jobs(p_shard, p_shards, p_account) j;
    return;
  end if;
  return query
  with pick as (
    select distinct on (r.plant) r.plant, r.lane
      from billing.reading_routes(p_at) r
     order by r.plant, r.via_share, r.since, r.lane
  )
  select p.plant,
         (select lp.plant_name from billing.login_plants lp
           where lp.plant = p.plant and lp.plant_name is not null order by lp.last_seen_at desc nulls last limit 1),
         coalesce(c.timezone, 'Africa/Johannesburg'), c.batt_positive_means,
         c.backfill_next::text, c.backfill_until::text, coalesce(c.backfill_tries, 0),
         c.temp_next::text, coalesce(c.temp_tries, 0), c.has_grid,
         sa.id, sa.user_id, sa.sunsynk_username, sa.access_token, sa.access_expires_at,
         bp.version
    from pick p
    join private.sunsynk_accounts sa on sa.id = p.lane
    join billing.plants bp on bp.id = p.plant
    left join public.plant_config c on c.plant_id = p.plant
   where case when p_account is not null then sa.id = p_account
              else ('x' || lpad(substr(replace(sa.id::text, '-', ''), 1, 8), 16, '0'))::bit(64)::bigint
                   % greatest(1, p_shards) = p_shard end
   order by p.plant;
end $$;

-- ---------------------------------------------------------------------------
-- The write guard. p_versions: {"<plant>": <version the fetch started on>}.
-- Locks the plant rows for share, so a seat change or a delete (both lock the row
-- for update) waits for the write, and a write waits for them.
-- ---------------------------------------------------------------------------
create function billing.write_allowed(p_versions jsonb, p_at timestamptz)
returns bigint[] language plpgsql set search_path = billing, pg_temp as $$
declare
  ok bigint[] := '{}';
  p record;
begin
  for p in select bp.id, bp.version from billing.plants bp
            where bp.id in (select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k)
            order by bp.id for share
  loop
    if p.version = (p_versions->>(p.id::text))::bigint
       and (billing.plant_state(p.id, p_at)->>'read_now')::boolean then
      ok := ok || p.id;
    end if;
  end loop;
  return ok;
end $$;

-- One plant; raises when the write may not land.
create function billing.guard_write(p_plant bigint, p_version bigint, p_at timestamptz)
returns void language plpgsql set search_path = billing, pg_temp as $$
begin
  if not billing.is_live() then return; end if;
  if p_version is null
     or cardinality(billing.write_allowed(jsonb_build_object(p_plant::text, p_version), p_at)) = 0 then
    raise exception 'plant % is not read now', p_plant using errcode = '55000';
  end if;
end $$;

-- New readings: the plant has history again.
create function billing.readings_arrived(p_plants bigint[])
returns void language sql set search_path = billing, pg_temp as $$
  update billing.plants set history_purged_at = null
   where id = any (p_plants) and history_purged_at is not null
$$;

create function billing.only_plants(p_rows jsonb, p_plants bigint[])
returns jsonb language sql immutable set search_path = pg_temp as $$
  select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) e
   where (e->>'plant_id')::bigint = any (p_plants)
$$;

create or replace function public.poll_commit_v2(
  p_versions  jsonb,
  p_account   uuid,
  p_ts        bigint,
  p_readings  jsonb,
  p_strings   jsonb,
  p_agg       jsonb,
  p_meta      jsonb,
  p_inverters jsonb,
  p_access    text,
  p_expires   bigint,
  p_at        timestamptz default now()
)
returns jsonb language plpgsql security definer set search_path = pg_temp as $$
declare
  ok bigint[];
  out jsonb;
begin
  if not billing.is_live() then
    return public.poll_commit(p_account, p_ts, p_readings, p_strings, p_agg, p_meta, p_inverters, p_access, p_expires);
  end if;
  ok := billing.write_allowed(p_versions, p_at);
  -- the token is saved whatever happens to the readings: the fetch may have refreshed it
  perform set_config('billing.guarded', 'on', true);
  out := public.poll_commit(p_account, p_ts, billing.only_plants(p_readings, ok), billing.only_plants(p_strings, ok),
                            billing.only_plants(p_agg, ok), billing.only_plants(p_meta, ok), p_inverters,
                            p_access, p_expires);
  perform set_config('billing.guarded', 'off', true);
  perform billing.readings_arrived(array(select jsonb_array_elements_text(coalesce(out->'plants', '[]'))::bigint));
  return out || jsonb_build_object('refused', to_jsonb(array(
    select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k where k::bigint <> all (ok) order by 1)));
end $$;

create or replace function public.q_insert_recovered_v2(p_plant bigint, p_version bigint, p_rows jsonb,
                                                        p_source text default 'plantfeed', p_at timestamptz default now())
returns integer language plpgsql security definer set search_path = pg_temp as $$
declare n integer;
begin
  perform billing.guard_write(p_plant, p_version, p_at);
  perform set_config('billing.guarded', 'on', true);
  n := public.q_insert_recovered(p_plant, p_rows, p_source);
  perform set_config('billing.guarded', 'off', true);
  if n > 0 then perform billing.readings_arrived(array[p_plant]); end if;
  return n;
end $$;

create or replace function public.q_insert_inverter_history_v2(p_plant bigint, p_version bigint, p_sn text, p_rows jsonb,
                                                               p_at timestamptz default now())
returns integer language plpgsql security definer set search_path = pg_temp as $$
declare n integer;
begin
  perform billing.guard_write(p_plant, p_version, p_at);
  perform set_config('billing.guarded', 'on', true);
  n := public.q_insert_inverter_history(p_plant, p_sn, p_rows);
  perform set_config('billing.guarded', 'off', true);
  if n > 0 then perform billing.readings_arrived(array[p_plant]); end if;
  return n;
end $$;

-- 0125's plant_row_guard. Since the switch-over plant_users.paused (the old "stopped")
-- is no longer kept up to date: a guarded write above has checked the plant already
-- (billing.guarded set for its transaction); any other write lands only on a plant read now.
create or replace function private.plant_row_guard()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.plant_id is null then return new; end if;
  if billing.is_live() then
    if current_setting('billing.guarded', true) = 'on' or tg_table_name in ('inverters', 'plant_config', 'meta')
       or coalesce((billing.plant_state(new.plant_id)->>'read_now')::boolean, false) then
      return new;
    end if;
    return null;
  end if;
  if pg_try_advisory_xact_lock_shared(new.plant_id)
     and exists (select 1 from public.plant_users pu where pu.plant_id = new.plant_id
                  and (not pu.paused or tg_table_name in ('inverters', 'plant_config', 'meta'))) then
    return new;
  end if;
  return null;
end $$;

-- Every missing minute of one local day, up to 10 minutes ago: the history queue's
-- days (q_missing_minutes counts only from the first stored minute or the backfill floor).
create or replace function public.q_missing_minutes_day(p_plant bigint, p_day date)
returns table (ts bigint) language sql stable set search_path = public, pg_temp as $$
  with b as (
    select public.day_start_epoch_tz(p_day, public.plant_tz(p_plant)) as lo,
           least(public.day_start_epoch_tz(p_day, public.plant_tz(p_plant)) + 86400,
                 extract(epoch from now())::bigint - 600) as hi)
  select g from b, generate_series(b.lo, b.hi - 60, 60) g
   where b.hi > b.lo
     and not exists (select 1 from public.agg_minute a where a.plant_id = p_plant and a.ts = g
                                                  and a.source <> 'poller_partial')
   order by g
$$;

-- ---------------------------------------------------------------------------
-- A stored login that breaks or is fixed (poll's account_mark, a relink) moves
-- billing.logins with it. Its plants' versions move, so in-flight reads stop.
-- ---------------------------------------------------------------------------
create function billing.login_status_follow()
returns trigger language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  want text := case new.status when 'active' then 'ok' when 'needs_relink' then 'needs_reconnect' end;
  l billing.logins;
begin
  -- 'disabled' (disconnected in the old screens) is not a broken login: remove_login handles it
  if want is null then return null; end if;
  update billing.logins set status = want where id = new.id and status <> want returning * into l;
  if l.id is not null then
    update billing.plants set version = version + 1
     where id in (select plant from billing.login_plants where login = l.id);
    perform billing.log_event(l.account, now(), 'poller', 'login_status',
                              jsonb_build_object('login', l.id, 'status', old.status),
                              jsonb_build_object('login', l.id, 'status', want));
  end if;
  return null;
end $$;
create trigger sunsynk_accounts_billing_status after update of status on private.sunsynk_accounts
  for each row when (old.status is distinct from new.status) execute function billing.login_status_follow();

-- ---------------------------------------------------------------------------
-- login_seen: the login's whole plant list from the poller's hourly refresh.
-- p_plants: [{"id": 123, "name": "Home"}, ...]. A plant missing from two lists
-- 50 minutes or more apart is gone (one short list from the cloud is not enough).
-- ---------------------------------------------------------------------------
alter table billing.login_plants add column missing_since timestamptz;   -- missing from the last list

create function billing.login_seen(p_login uuid, p_plants jsonb, p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  l billing.logins;
  ids bigint[];
  old_live bigint[];
  gone bigint[];
  back bigint[];
begin
  select * into l from billing.logins where id = p_login;
  if not found then return null; end if;
  perform billing.lock_account(l.account);
  ids := array(select distinct (e->>'id')::bigint from jsonb_array_elements(coalesce(p_plants, '[]')) e order by 1);
  old_live := array(select plant from billing.login_plants where login = l.id and gone_at is null order by 1);
  insert into billing.plants (id, brand, external_id)
  select x, l.brand, x::text from unnest(ids) x
  on conflict (id) do nothing;
  perform billing.lock_plants(ids || old_live);

  insert into billing.login_plants (login, plant, plant_name, last_seen_at, gone_at)
  select distinct on ((e->>'id')::bigint) l.id, (e->>'id')::bigint, e->>'name', p_at, null
    from jsonb_array_elements(coalesce(p_plants, '[]')) e
  on conflict (login, plant) do update set plant_name = coalesce(excluded.plant_name, login_plants.plant_name),
                                           last_seen_at = excluded.last_seen_at, gone_at = null, missing_since = null;
  with g as (
    update billing.login_plants set gone_at = p_at
     where login = l.id and gone_at is null and plant <> all (ids) and missing_since <= p_at - interval '50 minutes'
    returning plant)
  select coalesce(array_agg(plant order by plant), '{}') into gone from g;
  update billing.login_plants set missing_since = p_at
   where login = l.id and gone_at is null and plant <> all (ids) and missing_since is null;
  back := array(select x from unnest(ids) x where x <> all (old_live));

  if cardinality(gone) + cardinality(back) > 0 then
    -- the plants' versions move (in-flight reads stop); the account's does not, so a plant
    -- new or gone on the login never refunds a checkout in progress
    update billing.plants set version = version + 1 where id = any (gone || back);
    perform billing.log_event(l.account, p_at, 'poller', 'login_plants_seen',
                              jsonb_build_object('login', l.id, 'plants', to_jsonb(old_live)),
                              jsonb_build_object('gone', to_jsonb(gone), 'new', to_jsonb(back)));
  end if;
  return jsonb_build_object('gone', to_jsonb(gone), 'new', to_jsonb(back));
end $$;

-- ---------------------------------------------------------------------------
-- Job heartbeats
-- ---------------------------------------------------------------------------
create table billing.job_heartbeats (
  job           text primary key,
  last_run_at   timestamptz not null,
  last_result   jsonb,
  last_error    text,
  last_error_at timestamptz
);

create function billing.heartbeat(p_job text, p_at timestamptz, p_result jsonb, p_error text default null)
returns void language sql set search_path = billing, pg_temp as $$
  insert into billing.job_heartbeats (job, last_run_at, last_result, last_error, last_error_at)
  values (p_job, p_at, p_result, p_error, case when p_error is not null then p_at end)
  on conflict (job) do update set last_run_at = excluded.last_run_at, last_result = excluded.last_result,
    last_error = coalesce(excluded.last_error, job_heartbeats.last_error),
    last_error_at = coalesce(excluded.last_error_at, job_heartbeats.last_error_at)
$$;

-- ---------------------------------------------------------------------------
-- The delete job
-- ---------------------------------------------------------------------------
create function billing.has_history(p_plant bigint)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select exists (select 1 from public.agg_minute where plant_id = p_plant)
      or exists (select 1 from public.agg_5m where plant_id = p_plant)
      or exists (select 1 from public.readings where plant_id = p_plant)
      or exists (select 1 from public.plant_energy where plant_id = p_plant)
      or exists (select 1 from public.inverter_history where plant_id = p_plant)
      or exists (select 1 from public.grid_off where plant_id = p_plant)
$$;

-- A payment try under 24 hours old, still open, from an account that holds the plant
-- or is buying it: the payment may bring the plant back, so its history waits.
create function billing.payment_hold(p_plant bigint, p_at timestamptz)
returns boolean language sql stable set search_path = billing, pg_temp as $$
  select exists (
    select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
     where pa.status in ('created', 'pending', 'unknown')
       and pa.created_at <= p_at and pa.created_at > p_at - interval '24 hours'
       and (p_plant = any (i.plants)
            or exists (select 1 from billing.seats s where s.account = i.account and s.plant = p_plant
                          and s.closed_at is null)))
$$;

create function billing.delete_due(p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  p record;
  ps jsonb;
  deleted bigint[] := '{}';
  emptied bigint[] := '{}';
  held bigint[] := '{}';
  busy bigint[] := '{}';
  out jsonb;
begin
  if not billing.is_live() then return jsonb_build_object('live', false); end if;
  if not pg_try_advisory_xact_lock(hashtext('billing.delete_due')) then return jsonb_build_object('busy', true); end if;
  for p in select id from billing.plants where history_purged_at is null order by id loop
    ps := billing.plant_state(p.id, p_at);
    continue when ps->>'delete_at' is null or (ps->>'delete_at')::timestamptz > p_at;
    -- a plant being written now is left for the next run
    perform 1 from billing.plants where id = p.id for update skip locked;
    if not found then busy := busy || p.id; continue; end if;
    ps := billing.plant_state(p.id, p_at);
    continue when ps->>'delete_at' is null or (ps->>'delete_at')::timestamptz > p_at;
    if billing.payment_hold(p.id, p_at) then held := held || p.id; continue; end if;
    if billing.has_history(p.id) then
      perform private.plant_readings_delete(p.id);
      update public.plant_config set backfill_next = null, backfill_until = null, backfill_tries = 0, temp_next = null
       where plant_id = p.id;
      deleted := deleted || p.id;
    else
      emptied := emptied || p.id;              -- nothing stored: marked, so later sweeps skip it
    end if;
    update billing.plants set history_purged_at = p_at, version = version + 1 where id = p.id;
    update billing.history_fetches set status = 'dropped', drop_reason = 'deleted', finished_at = p_at, claimed_until = null
     where plant = p.id and status in ('queued', 'running');
  end loop;
  out := jsonb_build_object('deleted', to_jsonb(deleted), 'empty', cardinality(emptied),
                            'held', to_jsonb(held), 'busy', to_jsonb(busy));
  perform billing.heartbeat('delete', p_at, out);
  return out;
end $$;

-- ---------------------------------------------------------------------------
-- History fetch queue
-- ---------------------------------------------------------------------------
create table billing.history_fetches (
  id            bigint generated always as identity primary key,
  account       uuid   not null references billing.accounts (id) on delete cascade,
  plant         bigint not null references billing.plants (id) on delete cascade,
  fetch_no      int    not null,                 -- the account's nth fetch in 7 days
  target_s      int    not null,                 -- shortest time the whole fetch takes; 0 = normal speed
  status        text   not null default 'queued' check (status in ('queued', 'running', 'done', 'dropped')),
  drop_reason   text   check (drop_reason in ('switched_out', 'replaced', 'deleted')),
  lane          uuid,                            -- private.sunsynk_accounts id it runs through
  day_floor     date,                            -- walked from day_next back to day_floor
  day_next      date,
  days_total    int,
  tries         int    not null default 0,       -- failed tries on day_next
  version       bigint,                          -- plants.version when last handed out
  requested_at  timestamptz not null,
  started_at    timestamptz,
  next_step_at  timestamptz,
  claimed_until timestamptz,
  finished_at   timestamptz,
  check ((status = 'dropped') = (drop_reason is not null))
);
create unique index history_fetches_one_open on billing.history_fetches (account, plant) where status in ('queued', 'running');
create unique index history_fetches_one_per_lane on billing.history_fetches (lane) where status = 'running';
create index history_fetches_open on billing.history_fetches (status) where status in ('queued', 'running');

create table billing.history_lanes (
  lane          uuid primary key,
  backoff_s     int not null default 0,
  backoff_until timestamptz
);

-- One fetch per command: plants asked for at the same `at` share its number and speed,
-- whatever the number of plants. p_counts false (the first choice after a login is
-- linked, a checkout, an upgrade, a restart): normal speed, and it is not counted.
create function billing.request_history(p_account uuid, p_plants bigint[], p_at timestamptz, p_counts boolean default false)
returns void language plpgsql set search_path = billing, pg_temp as $$
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
  update billing.history_fetches set status = 'dropped', drop_reason = 'replaced', finished_at = p_at, claimed_until = null
   where account = p_account and plant = any (p_plants) and status in ('queued', 'running');
  insert into billing.history_fetches (account, plant, fetch_no, target_s, requested_at)
  select p_account, x, n, target, p_at from unnest(p_plants) x;
end $$;

-- 0242's write_seats, plus: new seats ask for a history fetch; closed seats drop theirs.
-- p_counts: the fetch counts toward the slower speed (an owner's switch only).
drop function billing.write_seats(uuid, bigint[], timestamptz, text);
create function billing.write_seats(p_account uuid, p_want bigint[], p_at timestamptz, p_reason text default 'switched',
                                    p_counts boolean default false)
returns void language plpgsql set search_path = billing, pg_temp as $$
declare had bigint[];
begin
  had := array(select plant from billing.seats where account = p_account and closed_at is null order by 1);
  update billing.seats set closed_at = p_at, close_reason = p_reason
   where account = p_account and closed_at is null and plant <> all (p_want);
  insert into billing.seats (account, plant, chosen_at)
  select p_account, x, p_at from unnest(p_want) x where x <> all (had);
  update billing.plants set trial_used_at = coalesce(trial_used_at, p_at),
                            trial_used_by = coalesce(trial_used_by, p_account)
   where id = any (p_want) and id <> all (had) and (trial_used_at is null or trial_used_by is null);
  update billing.plants set version = version + 1
   where id = any (p_want || had) and not (id = any (p_want) and id = any (had));
  update billing.history_fetches set status = 'dropped', drop_reason = 'switched_out', finished_at = p_at, claimed_until = null
   where account = p_account and status in ('queued', 'running') and plant = any (had) and plant <> all (p_want);
  perform billing.request_history(p_account, array(select x from unnest(p_want) x where x <> all (had)), p_at, p_counts);
end $$;

-- 0245's apply_purchase, plus: a plan restarted after it ended fetches the kept
-- plants' history again (new plants ask in write_seats, under the same fetch); a plan
-- the clock has ended but the job has not (cancel date or day 15 passed) is ended first.
create or replace function billing.apply_purchase(p_inv billing.invoices, p_at timestamptz)
returns void language plpgsql set search_path = billing, pg_temp as $$
declare
  m billing.markets;
  sid uuid;
  day int;
  pe timestamptz;
  had bigint[];
  restart boolean;
  old billing.subscriptions;
begin
  select mk.* into m from billing.markets mk join billing.accounts a on a.market = mk.code where a.id = p_inv.account;
  restart := (billing.account_status(p_inv.account, p_at)).state = 'ended';
  old := billing.live_sub(p_inv.account);
  if old.id is not null then
    if old.cancel_at_period_end and old.period_end <= p_at then
      perform billing.end_sub(old.id, old.period_end, 'cancelled', p_at, 'paystack', false);
    else
      perform billing.end_sub(old.id, coalesce(old.past_due_since + make_interval(days => (select max(d) from unnest(m.retry_days) d) + 1), p_at),
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
    perform billing.request_history(p_inv.account, array(select x from unnest(p_inv.plants) x where x = any (had)), p_at);
  end if;
end $$;

-- Starts what free lanes can take, then hands out the running fetches whose next
-- step is due: [{id, plant, account, day, floor, gap_s, version, timezone, login}].
create function billing.history_take(p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
declare
  q record;
  tz text;
  today date;
  out jsonb;
begin
  if not billing.is_live() then return '[]'::jsonb; end if;
  if not pg_try_advisory_xact_lock(hashtext('billing.history_take')) then return '[]'::jsonb; end if;
  update billing.history_fetches h set status = 'dropped', drop_reason = 'switched_out', finished_at = p_at, claimed_until = null
   where h.status in ('queued', 'running') and h.requested_at <= p_at and not billing.holds_plant(h.account, h.plant, p_at);

  -- a free lane starts its next request; on a shared lane the account whose last
  -- fetch there started longest ago (or never) goes first
  for q in
    select h.id, h.plant, x.lane from billing.history_fetches h
     cross join lateral (select billing.fetch_lane(h.account, h.plant) lane) x
     where h.status = 'queued' and h.requested_at <= p_at and x.lane is not null
     order by x.lane,
              (select max(o.started_at) from billing.history_fetches o where o.lane = x.lane and o.account = h.account) nulls first,
              h.requested_at, h.id
  loop
    continue when exists (select 1 from billing.history_fetches r where r.lane = q.lane and r.status = 'running')
               or exists (select 1 from billing.history_lanes hl where hl.lane = q.lane and hl.backoff_until > p_at);
    tz := coalesce((select c.timezone from public.plant_config c where c.plant_id = q.plant), 'Africa/Johannesburg');
    today := (p_at at time zone tz)::date;
    update billing.history_fetches
       set status = 'running', lane = q.lane, started_at = p_at, next_step_at = p_at,
           day_floor = today - 60, day_next = today - 1, days_total = 60, tries = 0
     where id = q.id;
  end loop;

  with w as (
    update billing.history_fetches h
       set claimed_until = p_at + interval '90 seconds',
           version = (select bp.version from billing.plants bp where bp.id = h.plant)
     where h.status = 'running' and h.next_step_at <= p_at and (h.claimed_until is null or h.claimed_until <= p_at)
       and not exists (select 1 from billing.history_lanes hl where hl.lane = h.lane and hl.backoff_until > p_at)
       and billing.reads_plant(h.account, h.plant, p_at)
       and exists (select 1 from private.sunsynk_accounts sa where sa.id = h.lane and sa.status = 'active')
    returning h.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', w.id, 'plant', w.plant, 'account', w.account, 'day', w.day_next, 'floor', w.day_floor,
           'target_s', w.target_s, 'version', w.version,
           'timezone', coalesce(c.timezone, 'Africa/Johannesburg'),
           'login', jsonb_build_object('id', sa.id, 'user_id', sa.user_id, 'sunsynk_username', sa.sunsynk_username,
                                       'access_token', sa.access_token, 'access_expires_at', sa.access_expires_at))
           order by w.id), '[]'::jsonb)
    into out
    from w join private.sunsynk_accounts sa on sa.id = w.lane
    left join public.plant_config c on c.plant_id = w.plant;
  perform billing.heartbeat('history', p_at, jsonb_build_object('handed_out', jsonb_array_length(out)));
  return out;
end $$;

-- After each day of a running fetch. p_day: the day just walked (null: the run
-- stops early, the fetch is free for the next run). p_failed: the day did not
-- answer (tried 3 times, then left). p_throttled: the cloud answered 429.
-- Returns {go, day, next_step_at}: go = this run may walk `day` at next_step_at.
create function billing.history_step(p_id bigint, p_day date, p_failed boolean default false,
                                     p_throttled boolean default false, p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
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
  if not billing.holds_plant(h.account, h.plant, p_at) then
    update billing.history_fetches set status = 'dropped', drop_reason = 'switched_out', finished_at = p_at, claimed_until = null
     where id = p_id;
    return jsonb_build_object('go', false, 'status', 'dropped');
  end if;
  if not billing.reads_plant(h.account, h.plant, p_at) then   -- broken login: waits for the fix
    update billing.history_fetches set claimed_until = null where id = p_id;
    return jsonb_build_object('go', false, 'status', 'waiting');
  end if;
  if p_throttled then
    insert into billing.history_lanes as hl (lane, backoff_s, backoff_until) values (h.lane, 60, p_at + interval '60 seconds')
    on conflict (lane) do update set backoff_s = least(greatest(hl.backoff_s * 2, 60), 3600),
                                     backoff_until = p_at + make_interval(secs => least(greatest(hl.backoff_s * 2, 60), 3600))
    returning backoff_s into wait_s;
    update billing.history_fetches set claimed_until = null, next_step_at = p_at + make_interval(secs => wait_s) where id = p_id;
    return jsonb_build_object('go', false, 'backoff_s', wait_s);
  end if;
  if p_day is null or p_day is distinct from h.day_next then
    update billing.history_fetches set claimed_until = null where id = p_id;
    return jsonb_build_object('go', false);
  end if;
  update billing.history_lanes set backoff_s = 0, backoff_until = null where lane = h.lane and backoff_s > 0;
  if p_failed and h.tries + 1 < 3 then
    update billing.history_fetches set tries = tries + 1, claimed_until = null, next_step_at = p_at + interval '1 minute'
     where id = p_id;
    return jsonb_build_object('go', false, 'retry', h.tries + 1);
  end if;
  if p_day - 1 < h.day_floor then
    update billing.history_fetches set status = 'done', day_next = p_day - 1, tries = 0, finished_at = p_at, claimed_until = null
     where id = p_id;
    return jsonb_build_object('go', false, 'status', 'done');
  end if;
  -- spread evenly: after `done` of days_total days, at least target_s * done / days_total since the start
  done := h.days_total - (p_day - h.day_floor);
  nxt := greatest(p_at, h.started_at + make_interval(secs => h.target_s::numeric * done / greatest(h.days_total, 1)));
  update billing.history_fetches
     set day_next = p_day - 1, tries = 0, next_step_at = nxt, claimed_until = nxt + interval '90 seconds'
   where id = p_id;
  return jsonb_build_object('go', true, 'day', p_day - 1, 'next_step_at', nxt);
end $$;

-- ---------------------------------------------------------------------------
-- Alerts
-- ---------------------------------------------------------------------------
create function billing.alerts(p_at timestamptz default now())
returns jsonb language sql stable security definer set search_path = billing, pg_temp as $$
  select coalesce(jsonb_agg(a order by a->>'kind', a->>'ref'), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'attempt_pending', 'ref', pa.reference, 'since', pa.created_at, 'status', pa.status) a
      from billing.payment_attempts pa
     where pa.status in ('created', 'pending', 'unknown') and pa.created_at <= p_at - interval '1 hour'
    union all
    select jsonb_build_object('kind', 'refund_failed', 'ref', r.reference, 'tries', r.tries, 'error', r.last_error)
      from billing.refunds r where r.status = 'failed'
    union all
    select jsonb_build_object('kind', 'outbox_backlog', 'ref', 'email_queue', 'waiting', count(*), 'oldest_due', min(q.due_at))
      from public.email_queue q where q.status = 'queued' and q.due_at <= p_at - interval '1 hour'
    having count(*) > 0
    union all
    select jsonb_build_object('kind', 'outbox_backlog', 'ref', 'billing_outbox', 'waiting', count(*), 'oldest_due', min(o.not_before))
      from billing.outbox o where o.status = 'queued' and o.not_before <= p_at - interval '1 hour'
    having count(*) > 0
    union all
    select jsonb_build_object('kind', 'history_unprotected', 'ref', p.id::text, 'delete_at', ps->'delete_at')
      from billing.plants p cross join lateral billing.plant_state(p.id, p_at) ps
     where p.history_purged_at is null and ps->>'delete_at' is not null
       and (ps->>'delete_at')::timestamptz <= p_at - interval '1 hour'
       and not billing.payment_hold(p.id, p_at) and billing.has_history(p.id)
    union all
    select jsonb_build_object('kind', 'many_switches', 'ref', e.account::text, 'switches', count(*))
      from billing.account_events e
     where e.kind = 'set_chosen_plants' and e.at > p_at - interval '7 days' and e.at <= p_at
       and e.before->'plants' is distinct from e.after->'plants'
     group by e.account having count(*) > 6
    union all
    select jsonb_build_object('kind', 'job_quiet', 'ref', j.job, 'last_run_at', h.last_run_at)
      from billing.switch_over so
     cross join (values ('delete', interval '30 minutes'), ('history', interval '10 minutes'),
                        ('billing-run', interval '26 hours')) j (job, quiet)
      left join billing.job_heartbeats h on h.job = j.job
     where coalesce(h.last_run_at, so.switched_at) <= p_at - j.quiet
  ) x
$$;

-- ---------------------------------------------------------------------------
-- "Came back after the win-back email" (winback_resubscribed_done, SOLAR-328):
-- a purchase paid after a win-back email went to that user. 0144's winback_return
-- read the old charges.
-- ---------------------------------------------------------------------------
create function billing.winback_return(p_reference text)
returns jsonb language sql stable security definer set search_path = billing, pg_temp as $$
  select jsonb_build_object('user', a.user_id, 'email_id', q.id, 'days', pa.settled_at::date - q.sent_at::date,
                            'at', pa.settled_at)
    from billing.payment_attempts pa
    join billing.invoices i on i.id = pa.invoice and i.kind = 'purchase'
    join billing.accounts a on a.id = i.account
    cross join lateral (select e.id, e.sent_at from public.email_queue e
                         where e.user_id = a.user_id and e.kind = 'winback' and e.status = 'sent'
                           and e.sent_at < pa.created_at
                         order by e.sent_at desc limit 1) q
   where pa.reference = p_reference and pa.status = 'success'
$$;

-- 0144's public.winback_return read the old charges; same answer, from the new tables.
create or replace function public.winback_return(p_reference text)
returns table (user_id uuid, email_id bigint, days int, at timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  select (w->>'user')::uuid, (w->>'email_id')::bigint, (w->>'days')::int, (w->>'at')::timestamptz
    from (select billing.winback_return(p_reference) w) x
   where w is not null
$$;
revoke all on function public.winback_return(text) from public, anon, authenticated;
grant execute on function public.winback_return(text) to service_role;

-- ---------------------------------------------------------------------------
-- The switch: run once at switch-over, after copy_from_old and the comparison.
-- ---------------------------------------------------------------------------
create function billing.switch_on(p_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
begin
  insert into billing.switch_over (switched_at) values (p_at) on conflict (id) do nothing;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobname) from cron.job
     where jobname in ('unpaid-delete', 'plant-wipe', 'billing-delete', 'billing-history');
    perform cron.schedule('billing-delete', '*/5 * * * *', 'select billing.delete_due()');
    perform cron.schedule('billing-history', '* * * * *', $c$select private.call_fn('recover?queue=1', '{}', 60000)$c$);
  end if;
  return jsonb_build_object('switched_at', (select switched_at from billing.switch_over));
end $$;

create function billing.unknown_command(p_cmd text)
returns jsonb language plpgsql set search_path = billing, pg_temp as $$
begin
  raise exception 'unknown billing_jobs command %', p_cmd using errcode = '22023';
end $$;

-- ---------------------------------------------------------------------------
-- The door for poll, recover and job-check (service role only).
-- ---------------------------------------------------------------------------
create or replace function public.billing_jobs(p_cmd text, p_args jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = billing, pg_temp as $$
begin
  return case p_cmd
    when 'history_take' then billing.history_take()
    when 'history_step' then billing.history_step((p_args->>'id')::bigint, (p_args->>'day')::date,
                               coalesce((p_args->>'failed')::boolean, false), coalesce((p_args->>'throttled')::boolean, false))
    when 'login_seen'   then billing.login_seen((p_args->>'login')::uuid, p_args->'plants')
    when 'alerts'       then billing.alerts()
    when 'heartbeat'    then (select '{}'::jsonb from (select billing.heartbeat(p_args->>'job', now(), p_args->'result',
                               p_args->>'error')) x)
    when 'winback'      then billing.winback_return(p_args->>'reference')
    else billing.unknown_command(p_cmd)
  end;
end $$;

revoke all on all tables in schema billing from public, anon, authenticated;
grant select on all tables in schema billing to service_role;
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'billing' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
revoke all on function public.poll_jobs_v2(int, int, uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.poll_commit_v2(jsonb, uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb, text, bigint, timestamptz) from public, anon, authenticated;
revoke all on function public.q_insert_recovered_v2(bigint, bigint, jsonb, text, timestamptz) from public, anon, authenticated;
revoke all on function public.q_insert_inverter_history_v2(bigint, bigint, text, jsonb, timestamptz) from public, anon, authenticated;
revoke all on function public.billing_jobs(text, jsonb) from public, anon, authenticated;
revoke all on function public.q_missing_minutes_day(bigint, date) from public, anon, authenticated;
grant execute on function public.q_missing_minutes_day(bigint, date) to service_role;
grant execute on function public.poll_jobs_v2(int, int, uuid, timestamptz) to service_role;
grant execute on function public.poll_commit_v2(jsonb, uuid, bigint, jsonb, jsonb, jsonb, jsonb, jsonb, text, bigint, timestamptz) to service_role;
grant execute on function public.q_insert_recovered_v2(bigint, bigint, jsonb, text, timestamptz) to service_role;
grant execute on function public.q_insert_inverter_history_v2(bigint, bigint, text, jsonb, timestamptz) to service_role;
grant execute on function public.billing_jobs(text, jsonb) to service_role;
grant execute on function billing.switch_on(timestamptz) to service_role;
grant execute on function billing.delete_due(timestamptz) to service_role;

notify pgrst, 'reload schema';
