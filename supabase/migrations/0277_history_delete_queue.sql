-- ============================================================================
-- 0277 — a plant's history is deleted in the background, not in the request (SOLAR-659).
--
-- Before: removing a plant or switching it out (api_link_remove, api_choose_plants, and the
-- delete job) ran private.plant_readings_delete inside the request, which has 8 s. Measured
-- 26 Nov 2026 on production: the parents' plant (495944) holds ~760k rows; only finding them
-- takes ~16 s cold (readings 4.6 s, agg_minute 4.2 s, inverter_history 2.8 s, strings 2.2 s),
-- 4 s+ warm. Its delete already failed the request. 5-minute rows are kept forever, so every
-- plant grows. The delete also held the account, login and plant locks the whole time.
--
-- Now:
--   1. billing.purge_now puts the plant on private.history_delete_queue instead of deleting.
--      The rest is as before: history_purged_at (history hidden, "History deleted"), version
--      bump (an in-flight write is refused), fetches dropped, backfill cleared; plus its
--      refill_queue row goes.
--   2. While a plant is on the list nothing reads or writes it: plant_state/plants_read_now/
--      reads_plant say not read (polls, history fetch and guard_write writers refused),
--      my_plant_ids hides it even if a seat reopens (a paid restart), account_state says
--      deleting. The writers with no version check (agg_minute_rollup, q_prune_inverter_history,
--      grid_off_update) take advisory key (8, 659) shared and skip a listed plant.
--   3. Choosing it again (set_chosen_plants) or picking it for a bill (final_choice) is refused
--      until it is off the list. A paid restart, renewal or grant is not refused: the plant waits.
--   4. private.history_delete_run, every minute: one run at a time; per plant, first waits for
--      the (8, 659) writers that started before it was listed, then deletes in batches with a
--      commit each: raw partitions one by one, then (after a running rollup slice finishes, key
--      (8, 651) shared) the other tables. Off the list after a whole pass finds nothing. One
--      history_delete_log row per plant, caller 'worker'.
--   5. history_delete_check: the 3 s alarm counts request deletes only; a plant listed over 1 h
--      fails it.
-- Not changed: batt_sign_detect (only rewrites rows; a pending plant is not polled), the poll
-- function, poll_commit*, rollup_old_days. private.plant_readings_delete stays for the old
-- (is_live false) paths.
-- ============================================================================

-- ── 1. the list ─────────────────────────────────────────────────────────────
create table if not exists private.history_delete_queue (
  plant_id   bigint primary key,
  queued_at  timestamptz not null default clock_timestamp(),
  fenced_at  timestamptz,                     -- the writers that started before it are done
  passes     integer not null default 0,
  wait_ms    integer not null default 0,
  raw_ms     integer not null default 0,
  rest_ms    integer not null default 0,
  counts     jsonb not null default '{}'::jsonb
);
alter table private.history_delete_queue enable row level security;
revoke all on table private.history_delete_queue from public, anon, authenticated;

create or replace function private.history_deleting(p_plant bigint)
returns boolean language sql stable security definer set search_path = private, pg_temp as $$
  select exists (select 1 from private.history_delete_queue where plant_id = p_plant)
$$;
revoke all on function private.history_deleting(bigint) from public, anon, authenticated;

-- A writer with no version check calls this first, then skips a listed plant. Held to the end
-- of its transaction, so the delete run's exclusive take waits for writers already under way.
create or replace function private.history_fence()
returns void language sql volatile set search_path = pg_temp as $$
  select pg_advisory_xact_lock_shared(8, 659)
$$;
revoke all on function private.history_fence() from public, anon, authenticated;

-- ── 2. remove: list the plant ──────────────────────────────────────────────
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
  delete from private.refill_queue where plant_id = p_plant;
  update public.plant_config set backfill_next = null, backfill_until = null, backfill_tries = 0, temp_next = null
   where plant_id = p_plant;
  update billing.plants set history_purged_at = p_at, version = version + 1 where id = p_plant;
  update billing.history_fetches set status = 'dropped', drop_reason = 'deleted', finished_at = p_at, claimed_until = null
   where plant = p_plant and status in ('queued', 'running');
  return jsonb_build_object('queued', 1);                                  -- 0277: delete_due counts it as deleted
end $function$;

-- ── 3. not read, not shown while listed ────────────────────────────────────
CREATE OR REPLACE FUNCTION billing.plant_state(p_plant bigint, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  p billing.plants;
  se record;
  st billing.status;
  is_protected boolean := false;
  is_read boolean := false;
  latest timestamptz;
  seat_count int := 0;
  delete_at timestamptz;
begin
  select * into p from billing.plants where id = p_plant;
  if not found then return null; end if;
  for se in select s.account from billing.seats s
             where s.plant = p_plant and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  loop
    seat_count := seat_count + 1;
    st := billing.account_status(se.account, p_at);
    if st.state in ('trialing', 'active', 'past_due') then
      is_protected := true;
      if not st.must_choose and billing.has_route(se.account, p_plant, true) then is_read := true; end if;
    elsif st.state = 'ended' and st.access_ended_at is not null then
      latest := greatest(latest, st.access_ended_at + make_interval(days => st.retention_days));
    end if;
  end loop;
  is_read := is_read and not private.history_deleting(p_plant);           -- 0277
  delete_at := case when is_protected or p.history_purged_at is not null then null
                    when seat_count = 0 then p_at
                    else latest end;
  return jsonb_build_object(
    'plant', p_plant,
    'protected', is_protected,
    'read_now', is_read,
    'delete_at', delete_at,
    'purged', p.history_purged_at is not null,
    'deleting', private.history_deleting(p_plant),                        -- 0277
    'open_seats', seat_count);
end $function$;

CREATE OR REPLACE FUNCTION billing.account_state(p_account uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  st billing.status;
  live boolean;
  next_retry timestamptz;
  fit text;
  plants jsonb;
  login_count int;
begin
  st := billing.account_status(p_account, p_at);
  if st is null then return null; end if;
  live := st.state in ('trialing', 'active', 'past_due');

  if st.state = 'past_due' then
    select min(st.past_due_since + make_interval(days => d)) into next_retry
      from unnest(st.retry_days) d where st.past_due_since + make_interval(days => d) > p_at;
  end if;

  -- the smallest plan that fits every linked plant; null when none does
  select p.code into fit from billing.plans p where p.places >= st.linked order by p.places limit 1;

  login_count := (select count(*) from billing.logins l where l.account = p_account);

  select coalesce(jsonb_agg(jsonb_build_object(
           'plant', x.plant,
           'name', coalesce((select lp.plant_name from billing.login_plants lp join billing.logins l on l.id = lp.login
                              where l.account = p_account and lp.plant = x.plant and lp.plant_name is not null limit 1),
                            (select c.plant_name from billing.plant_claims c where c.account = p_account and c.plant = x.plant),
                            -- a share removed (no claim left): the name it had
                            (select pu.plant_name from public.plant_users pu where pu.user_id = (select ac.user_id from billing.accounts ac where ac.id = p_account)
                                and pu.plant_id = x.plant and pu.plant_name is not null limit 1)),
           'chosen', x.chosen,
           'locked', not x.chosen,
           'read_now', x.chosen and live and not st.must_choose and billing.has_route(p_account, x.plant, true)
                       and not (ps->>'deleting')::boolean,                                         -- 0277
           'needs_reconnect', billing.has_route(p_account, x.plant, false) and not billing.has_route(p_account, x.plant, true),
           'trial_used_elsewhere', pl.trial_used_at is not null and pl.trial_used_by is distinct from p_account,
           'delete_at', ps->'delete_at',
           'purged', ps->'purged',
           'deleting', ps->'deleting') order by x.plant), '[]'::jsonb)          -- 0277: deleting
    into plants
    from (select y.plant, exists (select 1 from billing.seats se where se.account = p_account and se.plant = y.plant
                                     and se.chosen_at <= p_at and (se.closed_at is null or se.closed_at > p_at)) as chosen
            from (select t.x from billing.linked_plants(p_account) t (x)
                  union
                  select se.plant from billing.seats se where se.account = p_account
                     and se.chosen_at <= p_at and (se.closed_at is null or se.closed_at > p_at)) y (plant)) x
    join billing.plants pl on pl.id = x.plant
    cross join lateral billing.plant_state(x.plant, p_at) ps;

  return jsonb_build_object(
    'state', st.state,
    'plan', st.plan,
    'interval', st.interval,
    'amount_minor', st.amount_minor,
    'currency', st.currency,
    'places', st.places,
    'chosen', st.chosen,
    'linked', st.linked,
    'open', greatest(st.places - st.chosen, 0),
    'must_choose', st.must_choose,
    'trial_ends_at', st.trial_ends_at,
    'period_end', st.period_end,
    'cancel_at', st.cancel_at,
    'next_charge_at', case when st.state = 'active' and st.sub is not null and st.cancel_at is null then st.period_end
                           when st.state = 'past_due' then next_retry end,
    'next_retry_at', next_retry,
    'past_due_since', st.past_due_since,
    'plan_ends_at', st.plan_ends_at,
    'access_ended_at', st.access_ended_at,
    'may_add_login', case st.state when 'ended' then false
                                   when 'none' then login_count = 0
                                   when 'trialing' then login_count = 0
                                   else true end,
    'may_choose', st.state in ('trialing', 'active') or (st.state = 'none' and st.linked > 0),
    'may_switch', st.state in ('trialing', 'active'),
    'fit_all_plan', fit,
    'plants', plants) || billing.money_state(p_account, p_at, st.state) || billing.renewal_state(p_account, p_at, st);
end $function$;

CREATE OR REPLACE FUNCTION billing.plants_read_now(p_plants bigint[], p_at timestamp with time zone)
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  with se as (
    select s.account, s.plant from billing.seats s
     where s.plant = any (p_plants) and not private.history_deleting(s.plant)   -- 0277
       and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at)
  ), st as (
    select * from billing.accounts_live(array(select distinct account from se), p_at)
  )
  select distinct se.plant
    from se join st on st.account = se.account and st.live and not st.must_choose
   where exists (select 1 from billing.logins l join billing.login_plants lp on lp.login = l.id
                  where l.account = se.account and lp.plant = se.plant and lp.gone_at is null and l.status = 'ok')
      or exists (select 1 from billing.plant_claims c where c.account = se.account and c.plant = se.plant)
$function$;

CREATE OR REPLACE FUNCTION billing.reads_plant(p_account uuid, p_plant bigint, p_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  select exists (select 1 from billing.seats s where s.account = p_account and s.plant = p_plant
                    and s.chosen_at <= p_at and (s.closed_at is null or s.closed_at > p_at))
     and coalesce((select st.state in ('trialing', 'active', 'past_due') and not st.must_choose
                     from billing.account_status(p_account, p_at) st), false)
     and billing.has_route(p_account, p_plant, true)
     and not private.history_deleting(p_plant)                                -- 0277
$function$;

CREATE OR REPLACE FUNCTION public.my_plant_ids()
 RETURNS SETOF bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select se.plant from billing.seats se join billing.accounts a on a.id = se.account
    join billing.plants p on p.id = se.plant
   where a.user_id = auth.uid() and se.closed_at is null and p.history_purged_at is null
     and not private.history_deleting(se.plant)                                -- 0277
     -- a share removed or a plant gone from the login: hidden; its history stays and shows again
     and billing.has_route(a.id, se.plant, false)
     -- not paying (ended, or over its places): its own history only, never a plant another
     -- account keeps, whose seat here never closes (it would see that payer's readings for good)
     and ((select st.state in ('trialing', 'active', 'past_due') and not st.must_choose
             from billing.account_status(a.id, now()) st)
          or not billing.kept_elsewhere(a.id, se.plant, now()))
$function$;

-- ── 4. not chosen again while listed ───────────────────────────────────────
CREATE OR REPLACE FUNCTION billing.set_chosen_plants(p_account uuid, p_plants bigint[], p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  a billing.accounts;
  m billing.markets;
  st billing.status;
  want bigint[];
  had bigint[];
  bad bigint;
  next_places int;
  counted boolean;
begin
  a := billing.lock_account(p_account);
  select * into m from billing.markets where code = a.market;
  want := array(select distinct x from unnest(coalesce(p_plants, '{}')) x order by 1);
  had := array(select plant from billing.seats where account = p_account and closed_at is null order by 1);
  perform billing.lock_plants(want || had);
  st := billing.account_status(p_account, p_at);

  if st.state not in ('none', 'trialing', 'active') then
    raise exception 'plants cannot be chosen while the account is %', st.state using errcode = '22023';
  end if;
  -- a plant already chosen may stay chosen with no route (a share removed: kept, not read)
  select x into bad from unnest(want) x where not billing.has_route(p_account, x, false) and x <> all (had) limit 1;
  if found then
    raise exception 'plant % is not on this account''s logins', bad using errcode = '22023';
  end if;

  -- 0277: a plant switched back while its old history is still being deleted
  select x into bad from unnest(want) x where x <> all (had) and private.history_deleting(x) limit 1;
  if found then
    raise exception 'history of plant % is still being deleted', bad using errcode = '22023';
  end if;

  if st.state in ('none', 'trialing') then
    if cardinality(want) = 0 and st.state = 'none' then
      raise exception 'choose at least one plant to start the free week' using errcode = '22023';
    end if;
    select x into bad from unnest(want) x join billing.plants p on p.id = x
     where p.trial_used_at is not null and p.trial_used_by is distinct from p_account limit 1;
    if found then
      raise exception 'plant % already had its free week', bad using errcode = '22023';
    end if;
    if cardinality(want) > m.trial_places then
      raise exception 'the free week reads up to % plants', m.trial_places using errcode = '22023';
    end if;
    if st.state = 'none' then
      update billing.accounts set trial_started_at = p_at, trial_ends_at = p_at + make_interval(days => m.trial_days)
       where id = p_account;
    end if;
  elsif cardinality(want) > st.places then
    raise exception 'your plan has % places', st.places using errcode = '22023';
  else
    -- a booked downgrade: the plants not marked to drop must fit the next plan
    select coalesce(np.places, cp.places) + coalesce(sub.next_extra_places, sub.extra_places)
           + (st.places - cp.places - sub.extra_places)
      into next_places
      from billing.subscriptions sub
      join billing.plans cp on cp.code = sub.plan
      left join billing.prices pr on pr.id = sub.next_price
      left join billing.plans np on np.code = pr.plan
     where sub.id = st.sub and (sub.next_price is not null or sub.next_extra_places is not null);
    if next_places is not null and
       (select count(*) from unnest(want) x
         where not exists (select 1 from billing.seats se where se.account = p_account and se.plant = x
                              and se.closed_at is null and se.drop_at_period_end)) > next_places then
      raise exception 'your next plan has % places: pick the plants to drop first', next_places using errcode = '22023';
    end if;
  end if;

  -- the first choice after a login or a claim is linked is not a switch: its fetch never
  -- counts toward the slower history speed (0246 request_history)
  counted := exists (select 1 from billing.account_events e
                      where e.account = p_account and e.kind = 'set_chosen_plants'
                        and e.at > coalesce((select max(x.at) from billing.account_events x
                                              where x.account = p_account and x.kind in ('link_login', 'claim_plant')),
                                            '-infinity'));
  perform billing.write_seats(p_account, want, p_at, 'switched', counted);
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'set_chosen_plants',
                            jsonb_build_object('state', st.state, 'plants', to_jsonb(had)),
                            jsonb_build_object('plants', to_jsonb(want)));
  return billing.account_state(p_account, p_at);
end $function$;

CREATE OR REPLACE FUNCTION billing.final_choice(p_account uuid, p_plants bigint[], p_places integer)
 RETURNS bigint[]
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare want bigint[]; bad bigint;
begin
  if p_plants is null then raise exception 'choose the plants first' using errcode = '22023'; end if;
  want := array(select distinct x from unnest(p_plants) x order by 1);
  select x into bad from unnest(want) x where not billing.has_route(p_account, x, false)
     and not exists (select 1 from billing.seats se where se.account = p_account and se.plant = x and se.closed_at is null)
   limit 1;
  if found then raise exception 'plant % is not on this account''s logins', bad using errcode = '22023'; end if;
  -- 0277: not chosen now and its old history still being deleted
  select x into bad from unnest(want) x where private.history_deleting(x)
     and not exists (select 1 from billing.seats se where se.account = p_account and se.plant = x and se.closed_at is null)
   limit 1;
  if found then raise exception 'history of plant % is still being deleted', bad using errcode = '22023'; end if;
  if cardinality(want) > p_places then
    raise exception 'that plan has % places', p_places using errcode = '22023';
  end if;
  return want;
end $function$;

-- ── 5. writers with no version check ───────────────────────────────────────
CREATE OR REPLACE FUNCTION private.agg_minute_rollup(p_days integer DEFAULT 61)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  cutoff bigint := ((extract(epoch from now())::bigint - p_days * 86400) / 300) * 300;
  made bigint; gone bigint;
begin
  perform private.history_fence();                                         -- 0277
  insert into public.agg_5m
    (plant_id, ts, n, n_poller,
     pv_w_avg, pv_w_min, pv_w_max, load_w_avg, load_w_min, load_w_max,
     batt_w_avg, batt_w_min, batt_w_max, grid_w_avg, grid_w_min, grid_w_max,
     soc_avg, soc_min, soc_max, grid_in_w_avg, grid_out_w_avg, batt_pos_w_avg, batt_neg_w_avg)
  select plant_id, (ts / 300) * 300, count(*),
         count(*) filter (where coalesce(source, 'poller') = 'poller'),
         avg(pv_w), min(pv_w), max(pv_w), avg(load_w), min(load_w), max(load_w),
         avg(batt_w), min(batt_w), max(batt_w), avg(grid_w), min(grid_w), max(grid_w),
         avg(soc), min(soc), max(soc),
         avg(greatest(grid_w, 0)), avg(greatest(-grid_w, 0)),
         avg(greatest(batt_w, 0)), avg(greatest(-batt_w, 0))
    from public.agg_minute
   where ts < cutoff and plant_id is not null
     and plant_id not in (select q.plant_id from private.history_delete_queue q)   -- 0277
   group by plant_id, (ts / 300) * 300
  on conflict do nothing;
  get diagnostics made = row_count;

  delete from public.agg_minute where ts < cutoff and plant_id is not null;
  get diagnostics gone = row_count;
  return jsonb_build_object('buckets', made, 'minutes', gone);
end $function$;

CREATE OR REPLACE FUNCTION public.q_prune_inverter_history(p_plant bigint, p_days integer DEFAULT 31)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  cutoff bigint := ((extract(epoch from now())::bigint - p_days * 86400) / 300) * 300;
  n integer;
begin
  perform private.history_fence();                                         -- 0277
  if private.history_deleting(p_plant) then return 0; end if;
  insert into public.inverter_history_5m
    (plant_id, sn, ts, n, ac_max, dc_max, dc_min, vac_min, vac_max, vac_last, fac_min, fac_max, gfac_min, gfac_max)
  select plant_id, sn, (ts / 300) * 300, count(*),
         max(ac_c), max(dc_c), min(dc_c), min(vac_v), max(vac_v),
         (array_agg(vac_v order by ts desc) filter (where vac_v is not null))[1],
         min(fac_hz), max(fac_hz), min(grid_fac_hz), max(grid_fac_hz)
    from public.inverter_history
   where plant_id = p_plant and ts < cutoff
   group by plant_id, sn, (ts / 300) * 300
  on conflict do nothing;

  with del as (
    delete from public.inverter_history
     where plant_id = p_plant and ts < cutoff
    returning 1)
  select count(*) into n from del;
  return n;
end $function$;
-- recover calls it as service_role, which has no use of schema private: run as the owner
alter function public.q_prune_inverter_history(bigint, integer) security definer;

CREATE OR REPLACE FUNCTION private.grid_off_update(p_plant bigint, p_to bigint DEFAULT NULL::bigint)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  hi   bigint := coalesce(p_to, (extract(epoch from now())::bigint / 60) * 60 - 120);
  lo   bigint;
  open public.grid_off;
  m    record;
  n    integer := 0;
begin
  perform private.history_fence();                                         -- 0277
  if private.history_deleting(p_plant) then return 0; end if;
  select through_ts into lo from private.grid_off_progress where plant_id = p_plant;
  if lo is null then
    select min(r.ts) into lo from public.readings r where r.plant_id = p_plant;
  end if;
  if lo is null or lo >= hi then return 0; end if;

  select * into open from public.grid_off
   where plant_id = p_plant and ended_at is null
   order by started_at desc limit 1;

  for m in select * from private.grid_minutes(p_plant, lo, hi) order by ts loop
    n := n + 1;
    if not m.present then
      if open.plant_id is null then
        open := (p_plant, to_timestamp(m.ts), null, to_timestamp(m.ts), 0)::public.grid_off;
      end if;
      open.last_off_at := to_timestamp(m.ts);
      open.minutes_off := open.minutes_off + 1;
    elsif open.plant_id is not null then
      open.ended_at := to_timestamp(m.ts);
      insert into public.grid_off values (open.*)
      on conflict (plant_id, started_at) do update
        set ended_at = excluded.ended_at, last_off_at = excluded.last_off_at,
            minutes_off = excluded.minutes_off;
      open := null;
    end if;
  end loop;

  if open.plant_id is not null then
    insert into public.grid_off values (open.*)
    on conflict (plant_id, started_at) do update
      set last_off_at = excluded.last_off_at, minutes_off = excluded.minutes_off;
  end if;

  insert into private.grid_off_progress (plant_id, through_ts) values (p_plant, hi)
  on conflict (plant_id) do update set through_ts = excluded.through_ts;
  return n;
end $function$;

-- ── 6. the delete run ───────────────────────────────────────────────────────
create or replace procedure private.history_delete_run(p_cap interval default interval '45 seconds',
                                                      p_batch integer default 5000)
language plpgsql
as $$  -- no SET clause: a procedure with one cannot COMMIT
declare
  started timestamptz := clock_timestamp();
  q record;
  c record;
  t text;
  k text;
  n bigint;
  pass_rows bigint;
  t0 timestamptz;
  got boolean;
  no_fence boolean := false;
begin
  -- one run at a time; a session lock, as each commit lets transaction locks go
  if not pg_try_advisory_lock(8, 6590) then return; end if;

  <<plants>>
  loop
    exit when clock_timestamp() - started > p_cap;
    -- without the fence this run, only plants already fenced
    select * into q from private.history_delete_queue where not no_fence or fenced_at is not null
     order by queued_at, plant_id limit 1;
    exit when not found;

    -- the writers with no version check that began before the plant was listed end first;
    -- try, never queue for it (a queued take would stall every writer behind it)
    if q.fenced_at is null then
      t0 := clock_timestamp();
      got := false;
      for i in 1..50 loop
        if pg_try_advisory_xact_lock(8, 659) then got := true; exit; end if;
        perform pg_sleep(0.1);
      end loop;
      if not got then no_fence := true; continue; end if;
      update private.history_delete_queue
         set fenced_at = clock_timestamp(), wait_ms = wait_ms + round(extract(epoch from clock_timestamp() - t0) * 1000)
       where plant_id = q.plant_id;
      commit;
    end if;

    pass_rows := 0;
    -- raw minutes: one day partition at a time
    for c in select ch.oid::regclass::text as rel, pa.relname as parent
               from pg_inherits i join pg_class ch on ch.oid = i.inhrelid join pg_class pa on pa.oid = i.inhparent
              where i.inhparent in ('public.readings'::regclass, 'public.strings'::regclass)
              order by pa.relname, ch.relname loop
      loop
        exit plants when clock_timestamp() - started > p_cap;
        t0 := clock_timestamp();
        begin
          execute format('delete from %s where ctid = any (array(select ctid from %s where plant_id = $1 limit $2))', c.rel, c.rel)
            using q.plant_id, p_batch;
          get diagnostics n = row_count;
        exception when undefined_table then
          n := 0;   -- the nightly rollup dropped the day meanwhile
        end;
        update private.history_delete_queue
           set raw_ms = raw_ms + round(extract(epoch from clock_timestamp() - t0) * 1000),
               counts = counts || jsonb_build_object(c.parent, coalesce((counts->>c.parent)::bigint, 0) + n)
         where plant_id = q.plant_id;
        commit;
        pass_rows := pass_rows + n;
        exit when n < p_batch;
      end loop;
    end loop;

    -- a rollup slice that read the raw rows before they went ends first, so its 5-minute
    -- rows are there to delete below (it holds (8, 651) exclusive; nothing is locked here).
    -- Tried, not waited for: the run keeps to its cap; the next run carries on.
    t0 := clock_timestamp();
    got := false;
    for i in 1..50 loop
      if pg_try_advisory_xact_lock_shared(8, 651) then got := true; exit; end if;
      perform pg_sleep(0.1);
    end loop;
    exit plants when not got;
    update private.history_delete_queue set wait_ms = wait_ms + round(extract(epoch from clock_timestamp() - t0) * 1000)
     where plant_id = q.plant_id;
    commit;

    -- sources before what is made from them
    foreach t in array array['public.agg_minute', 'public.inverter_history', 'public.readings_5m', 'public.strings_5m',
                             'public.agg_5m', 'public.inverter_history_5m', 'public.plant_energy', 'public.grid_off',
                             'private.gaps', 'private.grid_off_progress'] loop
      k := split_part(t, '.', 2);
      loop
        exit plants when clock_timestamp() - started > p_cap;
        t0 := clock_timestamp();
        execute format('delete from %s where ctid = any (array(select ctid from %s where plant_id = $1 limit $2))', t, t)
          using q.plant_id, p_batch;
        get diagnostics n = row_count;
        update private.history_delete_queue
           set rest_ms = rest_ms + round(extract(epoch from clock_timestamp() - t0) * 1000),
               counts = counts || jsonb_build_object(k, coalesce((counts->>k)::bigint, 0) + n)
         where plant_id = q.plant_id;
        commit;
        pass_rows := pass_rows + n;
        exit when n < p_batch;
      end loop;
    end loop;

    -- a whole pass found nothing: done
    update private.history_delete_queue set passes = passes + 1 where plant_id = q.plant_id;
    if pass_rows = 0 then
      insert into private.history_delete_log (plant_id, caller, timeout, wait_ms, raw_ms, rest_ms, counts)
      select plant_id, 'worker', current_setting('statement_timeout', true), wait_ms, raw_ms, rest_ms, counts
        from private.history_delete_queue where plant_id = q.plant_id;
      delete from private.history_delete_queue where plant_id = q.plant_id;
    end if;
    commit;
  end loop;

  perform pg_advisory_unlock(8, 6590);
end $$;
revoke all on procedure private.history_delete_run(interval, integer) from public, anon, authenticated;

-- ── 7. the alarm ────────────────────────────────────────────────────────────
-- 0270's check, with: the 3 s limit counts deletes in a request only (the run's are long by
-- design), and a plant listed over an hour fails it.
create or replace procedure private.history_delete_check(p_slow_ms integer default 3000)
language plpgsql
as $$  -- no SET clause: a procedure with one cannot COMMIT
declare
  w record;
begin
  delete from private.history_delete_log where at < now() - interval '90 days';
  commit;  -- kept when the alarm below fails the run

  select * into w from (
    select plant_id::text as what, caller, wait_ms + raw_ms + rest_ms as ms, wait_ms, raw_ms, rest_ms
      from private.history_delete_log where at > now() - interval '24 hours' and caller <> 'worker'   -- 0277
    union all
    select count(*) || ' plants', min(caller), sum(wait_ms + raw_ms + rest_ms), sum(wait_ms), sum(raw_ms), sum(rest_ms)
      from private.history_delete_log where at > now() - interval '24 hours' and caller in ('authenticated', 'service_role')
     group by xid having count(*) > 1
  ) t where ms > p_slow_ms order by ms desc limit 1;
  if found then
    raise exception 'history delete over % ms in 24 h: % % % ms (wait %, raw %, rest %), see SOLAR-659',
      p_slow_ms, w.what, w.caller, w.ms, w.wait_ms, w.raw_ms, w.rest_ms;
  end if;

  select plant_id, queued_at, passes, counts into w from private.history_delete_queue          -- 0277
   where queued_at < now() - interval '1 hour' order by queued_at limit 1;
  if found then
    raise exception 'history of plant % waiting to be deleted since % (% passes, so far %), see SOLAR-659',
      w.plant_id, w.queued_at, w.passes, w.counts;
  end if;
end $$;
revoke all on procedure private.history_delete_check(integer) from public, anon, authenticated;

-- ── 8. cron ─────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'history-delete') then
    perform cron.unschedule('history-delete');
  end if;
  perform cron.schedule('history-delete', '* * * * *', 'call private.history_delete_run()');
end $$;
