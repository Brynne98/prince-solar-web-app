-- ============================================================================
-- 0204 — a plant nobody pays for is not read, and its data goes 30 days later
--        (SOLAR-552, decided by Brynne 2026-11-15).
--
-- Before: a plant of an account with no plan was read every minute for good, and
-- the hourly trim (0111) kept its last 24 hours.
--
-- Now:
--   - public.live_plants: the plants read. A plant is read when an account that
--     runs it has a plan or is in its free week on that plant (plant_live, 0203).
--     poll_jobs and plantsToPoll (sunsynk.ts) go by it, so the minute poll, recover
--     and the day totals all stop at day 7. An account in a failed card's 30 days
--     reads its history; the plant is not read for it.
--   - private.unpaid_delete, hourly: a plant's readings are deleted when every
--     account that runs it has had no plan for 30 days (unpaid_since, 0203): day 37
--     from the link, or 30 days after the paid time ended. A cancel no longer
--     deletes on its end date (0188). The link, the settings and the ticks stay.
--   - Paying starts the reading again and fetches the last 60 days
--     (billing_restart, in place of billing_refill_trimmed).
--   - Gone: the hourly trim (free_trim, free_trimmed_plants, free_trim_done, the
--     free-trim job) and the "free week ended" notice (the pay screen says it).
--
-- Existing accounts with no plan, past their week: counted from this migration,
-- so nothing is deleted at deploy and the two emails (0205) go on day 14 and 27.
-- ============================================================================

insert into private.billing (user_id, ended_at)
select f.user_id, now()
  from private.free_week_logins f
  left join private.billing b on b.user_id = f.user_id
 where coalesce(b.plan, 'free') = 'free' and f.started_at <= now() - interval '7 days'
on conflict (user_id) do update set ended_at = excluded.ended_at
  where private.billing.plan = 'free';

-- The plants that are read. Server only.
create or replace function public.live_plants()
returns setof bigint
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select distinct pu.plant_id
    from public.plant_users pu
   where not pu.paused and pu.share_gone_at is null
     and private.plant_live(pu.user_id, pu.plant_id)
$$;
revoke all on function public.live_plants() from public, anon, authenticated;
grant execute on function public.live_plants() to service_role;

-- ---------------------------------------------------------------------------
-- 0172's poll_jobs, for the links that are read (plant_live).
-- ---------------------------------------------------------------------------
create or replace function public.poll_jobs(p_shard int, p_shards int, p_account uuid default null)
returns table (
  plant_id bigint, plant_name text, timezone text, batt_positive_means text,
  backfill_next text, backfill_until text, backfill_tries int,
  temp_next text, temp_tries int, has_grid boolean,
  account_id uuid, user_id uuid, sunsynk_username text, access_token text, access_expires_at bigint)
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  with acc as (
    select a.id, a.user_id, a.sunsynk_username, a.access_token, a.access_expires_at,
           row_number() over (order by a.linked_at, a.id) as rank,
           ('x' || lpad(substr(replace(a.id::text, '-', ''), 1, 8), 16, '0'))::bit(64)::bigint
             % greatest(1, p_shards) as shard
      from private.sunsynk_accounts a
     where a.status = 'active'
  ),
  pick as (
    select distinct on (pu.plant_id) pu.plant_id, pu.plant_name, acc.*
      from public.plant_users pu
      join acc on acc.id = pu.account_id
     where pu.share_gone_at is null and not pu.paused
       and private.plant_live(pu.user_id, pu.plant_id)
     order by pu.plant_id, acc.rank
  )
  select p.plant_id, p.plant_name,
         coalesce(c.timezone, 'Africa/Johannesburg'), c.batt_positive_means,
         c.backfill_next::text, c.backfill_until::text, coalesce(c.backfill_tries, 0),
         c.temp_next::text, coalesce(c.temp_tries, 0), c.has_grid,
         p.id, p.user_id, p.sunsynk_username, p.access_token, p.access_expires_at
    from pick p
    left join public.plant_config c on c.plant_id = p.plant_id
   where case when p_account is not null then p.id = p_account else p.shard = p_shard end
   order by p.plant_id
$$;

-- ---------------------------------------------------------------------------
-- 0174's plant_start_fill: a plant that is not read gets no 60-day bookmarks
-- (it was: a plant on the trim list).
-- ---------------------------------------------------------------------------
create or replace function private.plant_start_fill(p_plant bigint)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare tz text;
begin
  -- After a wipe that is running now, never under it.
  perform pg_advisory_xact_lock(p_plant);
  delete from private.plant_wipe where plant_id = p_plant;
  if not exists (select 1 from public.plant_config where plant_id = p_plant) then
    -- Linked stopped, so never seeded (sunsynk.ts syncPlants). South Africa only;
    -- the seed sets the 60-day bookmarks.
    perform public.plant_config_seed(jsonb_build_array(jsonb_build_object('plant_id', p_plant)));
  else
    select coalesce(timezone, 'Africa/Johannesburg') into tz from public.plant_config where plant_id = p_plant;
    update public.plant_config
       set backfill_next = (now() at time zone tz)::date - 60,
           backfill_until = (now() at time zone tz)::date - 14,
           backfill_tries = 0,
           temp_next = (now() at time zone tz)::date - 60
     where plant_id = p_plant;
  end if;
  if p_plant not in (select public.live_plants()) then
    update public.plant_config set backfill_next = null, backfill_until = null, temp_next = null
     where plant_id = p_plant;
  end if;
  -- No readings counts from here (0174): the reading time kept from before the stop is old.
  insert into private.plant_alert_state (plant_id, started_at) values (p_plant, extract(epoch from now())::bigint)
  on conflict (plant_id) do update set started_at = excluded.started_at;
  perform public.plant_bootstrap_kick(p_plant);
end $$;
revoke all on function private.plant_start_fill(bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The plants to keep when a plan with fewer places starts: the free week runs up
-- to 5 plants and Home has 2. The owner ticks them before paying; the start reads
-- the list (billing_restart) and clears it. With none ticked, the first linked stay.
-- ---------------------------------------------------------------------------
create or replace function public.api_billing_start_keep(p_plants bigint[])
returns void
language plpgsql security definer set search_path = public, private, pg_temp
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(uid);
  if coalesce((select plan from private.billing where user_id = uid), 'free') <> 'free' then
    raise exception 'nothing to pick' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(coalesce(p_plants, '{}')) x
              where not exists (select 1 from public.plant_users pu where pu.user_id = uid and pu.plant_id = x and not pu.paused)) then
    raise exception 'a plant is not running for this user' using errcode = '42501';
  end if;
  insert into private.billing (user_id, next_keep) values (uid, coalesce(p_plants, '{}'))
  on conflict (user_id) do update set next_keep = excluded.next_keep, updated_at = now();
end $$;
revoke all on function public.api_billing_start_keep(bigint[]) from public, anon;
grant execute on function public.api_billing_start_keep(bigint[]) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- A plan starts on an account that had none.
--   - More plants run than the plan has places: the plants over it are locked,
--     the ticked ones (api_billing_start_keep) kept first, then the first linked.
--     A locked plant keeps its tick without its place and loses its history, as a
--     plant changed out does (0197); a bigger plan starts it again with a fetch.
--   - Each plant it runs that was not read starts again with the 60-day fetch
--     (plant_start_fill). A plant in the account's free week, or read for another
--     account, has its history already.
-- ---------------------------------------------------------------------------
create or replace function private.billing_restart()
returns trigger
language plpgsql security definer set search_path = public, private, pg_temp
as $$
declare p bigint;
begin
  if new.plan = 'free' or (tg_op = 'UPDATE' and old.plan <> 'free') then return new; end if;
  if not new.comped then
    with stop as (
      update public.plant_users set paused = true
       where user_id = new.user_id and plant_id in (
         select plant_id from public.plant_users
          where user_id = new.user_id and not paused
          order by array_position(new.next_keep, plant_id) nulls last, linked_at, plant_id
         offset public.billing_room(new.plan, new.extra_plants))
      returning plant_id)
    insert into private.plant_wipe (plant_id)
    select s.plant_id from stop s
     -- the rows just locked still read as running inside this statement
     where not exists (select 1 from public.plant_users o
                        where o.plant_id = s.plant_id and o.user_id <> new.user_id and not o.paused)
    on conflict (plant_id) do nothing;
    update private.billing set next_keep = '{}' where user_id = new.user_id and next_keep <> '{}';
  end if;
  for p in
    select pu.plant_id from public.plant_users pu
     where pu.user_id = new.user_id and not pu.paused and pu.share_gone_at is null
       and not private.plant_in_week(pu.user_id, pu.plant_id)
       and not exists (select 1 from public.plant_users o
                        where o.plant_id = pu.plant_id and o.user_id <> pu.user_id
                          and not o.paused and o.share_gone_at is null
                          and private.plant_live(o.user_id, o.plant_id))
     order by pu.plant_id
  loop
    perform private.plant_start_fill(p);
  end loop;
  return new;
end $$;
revoke all on function private.billing_restart() from public, anon, authenticated;
drop trigger if exists billing_refill_trimmed on private.billing;
drop function if exists private.billing_refill_trimmed();
drop trigger if exists billing_restart on private.billing;
create trigger billing_restart after insert or update of plan on private.billing
  for each row execute function private.billing_restart();

-- 0150's readings delete, without the trim's marker.
create or replace function private.plant_readings_delete(p_plant bigint)
returns jsonb
language plpgsql
set search_path to 'public', 'private', 'pg_temp'
as $function$
declare
  out jsonb := '{}'::jsonb;
  n bigint;
begin
  delete from public.readings            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings', n);
  delete from public.strings             where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings', n);
  delete from public.readings_5m         where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('readings_5m', n);
  delete from public.strings_5m          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('strings_5m', n);
  delete from public.agg_minute          where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_minute', n);
  delete from public.agg_5m              where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('agg_5m', n);
  delete from public.plant_energy        where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('plant_energy', n);
  delete from public.inverter_history    where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history', n);
  delete from public.inverter_history_5m where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('inverter_history_5m', n);
  delete from public.grid_off            where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('grid_off', n);
  delete from private.gaps               where plant_id = p_plant; get diagnostics n = row_count; out := out || jsonb_build_object('gaps', n);
  delete from private.grid_off_progress  where plant_id = p_plant;
  return out;
end $function$;

-- ---------------------------------------------------------------------------
-- The delete. A plant whose every running account has had no plan for 30 days
-- (and is past a failed card's 30 days): its readings go. A plant with nothing
-- stored is passed over. Hourly, in place of the trim.
-- ---------------------------------------------------------------------------
create or replace function private.unpaid_delete()
returns jsonb
language plpgsql security definer set search_path = public, private, pg_temp
as $$
declare
  p bigint;
  plants int := 0;
  total bigint := 0;
begin
  for p in
    select pu.plant_id
      from public.plant_users pu
      left join private.billing b on b.user_id = pu.user_id
     where not pu.paused
     group by pu.plant_id
    having bool_and(not private.plant_live(pu.user_id, pu.plant_id)
                    and private.unpaid_since(pu.user_id) + interval '30 days' <= now()
                    and (b.keep_until is null or b.keep_until < private.billing_today()))
     order by pu.plant_id
  loop
    perform pg_advisory_xact_lock(p);
    -- a payment or a link that landed while this run waited for the lock
    continue when exists (select 1 from public.plant_users pu
                           where pu.plant_id = p and not pu.paused
                             and (private.plant_live(pu.user_id, p)
                                  or private.unpaid_since(pu.user_id) + interval '30 days' > now()));
    continue when not (exists (select 1 from public.agg_minute where plant_id = p)
                    or exists (select 1 from public.agg_5m where plant_id = p)
                    or exists (select 1 from public.readings where plant_id = p)
                    or exists (select 1 from public.plant_energy where plant_id = p)
                    or exists (select 1 from public.grid_off where plant_id = p));
    plants := plants + 1;
    total := total + (select coalesce(sum(v::bigint), 0) from jsonb_each_text(private.plant_readings_delete(p)) as t(k, v));
    update public.plant_config
       set backfill_next = null, backfill_until = null, backfill_tries = 0, temp_next = null
     where plant_id = p;
  end loop;
  return jsonb_build_object('plants', plants, 'rows', total);
end $$;
revoke all on function private.unpaid_delete() from public, anon, authenticated;

-- plantsToPoll (sunsynk.ts) reads poll_jobs now, so the second list of logins is not used.
drop function if exists public.accounts_active();
drop function if exists private.free_trim();
drop function if exists public.free_trimmed_plants();
drop table if exists private.free_trim_done;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not enabled here - skipping jobs (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'free-trim') then
    perform cron.unschedule('free-trim');
  end if;
  if exists (select 1 from cron.job where jobname = 'unpaid-delete') then
    perform cron.unschedule('unpaid-delete');
  end if;
  perform cron.schedule('unpaid-delete', '20 * * * *', 'select private.unpaid_delete()');
end $$;

-- ---------------------------------------------------------------------------
-- 0190's billing_notices, without free_week_ended: the pay screen says it.
-- ---------------------------------------------------------------------------
create or replace function private.billing_notices()
returns jsonb language plpgsql stable set search_path = public, private, pg_temp as $$
declare
  me uuid := auth.uid();
  b private.billing;
  today date := private.billing_today();
  st jsonb;
  started timestamptz;
  first_plant bigint;
  out jsonb := '[]';
  booked boolean;
begin
  select * into b from private.billing where user_id = me;
  booked := b.next_plan is not null or b.next_period is not null or b.next_extra_plants is not null;

  if b.state = 'past_due' and b.plan <> 'free' then
    -- the same next try and Free date as Billing shows
    st := public.api_billing_status();
    out := out || jsonb_build_object('kind', 'bill_failed', 'plan', b.plan, 'amount', st->'nextAmount',
                                     'nextTry', st->'nextTry', 'freeOn', st->'freeOn');
  end if;

  if b.remove_on > today and b.remove_on <= today + 3 and cardinality(b.plants_to_remove) > 0 then
    -- room: the plants the plan covers from that date (a booked change, else today's plan)
    out := out || jsonb_build_object('kind', 'bill_removal_soon', 'on', b.remove_on,
      'room', coalesce(private.billing_next_room(b), public.billing_room(b.plan, b.extra_plants)),
      'plants', coalesce((select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                   from plant_users pu where pu.user_id = me and pu.plant_id = any (b.plants_to_remove)), '[]'));
  end if;

  -- after a failed payment only (bill_free's email), not a cancel that ended (winback)
  if b.plan = 'free' and exists (select 1 from email_queue q where q.user_id = me and q.kind = 'bill_free'
                                   and q.created_at > now() - interval '30 days') then
    out := out || jsonb_build_object('kind', 'bill_free', 'deleteOn', b.remove_on,
      'kept', (select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                 from plant_users pu where pu.user_id = me and not pu.paused),
      'stopped', (select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                    from plant_users pu where pu.user_id = me and pu.plant_id = any (coalesce(b.plants_to_remove, '{}'))));
  end if;

  -- a paid switch to yearly (prepaid_on, 0138) has nothing to undo; a cancel in it does (SOLAR-467)
  if b.plan <> 'free' and not b.comped and b.state = 'active' and booked
     and (b.prepaid_on is null or b.next_plan = 'free') then
    out := out || jsonb_build_object('kind', 'bill_change',
      'on', case when b.prepaid_on is not null then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                 else b.next_billing_date end,
      'plan', b.plan, 'period', b.period, 'nextPlan', b.next_plan, 'nextPeriod', b.next_period,
      'extraPlants', coalesce(b.extra_plants, 0), 'nextExtraPlants', b.next_extra_plants);
  end if;

  if b.period = 'yearly' and not b.comped and b.state = 'active' and not booked
     and b.next_billing_date > today and b.next_billing_date <= today + 60 then
    out := out || jsonb_build_object('kind', 'bill_renewal_notice', 'plan', b.plan, 'on', b.next_billing_date,
                                     'amount', public.billing_amount_due(me));
  end if;

  -- the free week: never paid, as free_week_mail (0145) reads it
  if coalesce(b.plan, 'free') = 'free' and not coalesce(b.comped, false) and b.keep_until is null then
    select min(f.started_at) into started from private.free_week_logins f where f.user_id = me;
    if now() >= started + interval '5 days' and now() < started + interval '7 days' then
      select pu.plant_id into first_plant from plant_users pu where pu.user_id = me and not pu.paused
       order by pu.linked_at, pu.plant_id limit 1;
      out := out || jsonb_build_object('kind', 'free_week_soon',
        'endsAt', started + interval '7 days',
        'plant', (select coalesce(pu.plant_name, 'Plant ' || pu.plant_id) from plant_users pu
                   where pu.user_id = me and pu.plant_id = first_plant),
        'days', (select count(*) from plant_energy e
                  where e.plant_id = first_plant and e.bucket = 'day'
                    and e.period < public.today_tz(public.plant_tz(first_plant))),
        'perMonth', (private.billing_price_list(private.billing_offer_now(me)) #>> '{monthly,home}')::int,
        'list', (private.billing_price_list(null) #>> '{monthly,home}')::int);
    end if;
  end if;

  return out;
end $$;
revoke all on function private.billing_notices() from public, anon, authenticated;

notify pgrst, 'reload schema';
