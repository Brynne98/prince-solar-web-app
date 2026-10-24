-- ============================================================================
-- 0092 — The 17 emails we send ourselves get triggers and a sender. (SOLAR-157)
--
-- Until now nothing sent mail. api_alerts_due (0057) detected eight plant events,
-- but its only reader (alerts-due) watched one plant and had no caller, and nothing
-- remembered what had gone out. The notify function (pg_cron, every minute) now
-- reads the readers below, checks email_wanted (0091), claims a row in email_sent,
-- and sends through Resend.
--
--  email_sent      one row per email per user; unique (user_id, key) makes a send
--                  happen once. "Down" rows (grid_down, logger_stale, sunsynk_down)
--                  stay open (closed_at null) until their "back" email goes out.
--  email_outbox    the address of a deleted account, kept until "account deleted"
--                  goes out; api_account_delete writes it before the user row goes.
--  email_plant_events(plant)  per-plant triggers, as the email mock words them:
--     grid_down     newest 3 known minutes have no grid (>100 V on q_grid_present);
--                   since = the first off minute after the last on minute.
--                   One per outage, however short (decision C, 2026-10-24).
--     grid_on       newest 2 known minutes have grid; closes an open grid_down
--     batt_hot      newest battery temperature above 40 C (was 35 in api_balance,
--                   which the TODO app still reads, so it stays there)
--     bank_drift    charge 10 points or more apart between inverters on every
--                   sample for the last hour (was 5 points for 10 minutes)
--     string_dead   0057's rule (11:00-14:59, dead 15 min while a sibling makes
--                   >200 W); the first dead string, by inverter order
--     logger_stale  SunSynk has no new reading (newest device_time across the
--                   plant) for 15 min while our own polls still land. Before, it
--                   was our agg_minute.ts going stale, so our failed polls fired it
--                   and SunSynk's silence didn't (carried rows kept ts fresh).
--     logger_ok     SunSynk readings are fresh; closes an open logger_stale
--  email_sunsynk_state()  SunSynk down: no login got an answer for 10 minutes
--                  (decision A) while the poll cron is running. Up: an answer in
--                  the last 2 minutes.
--  email_hot_days(plant)  days above 40 C in the last 30, read when batt_hot goes
--  email_relinks()  logins marked needs_relink in the last 2 days
--  email_users()    who to mail: address, plants, the login that reaches each
--  email_history_done()  plants whose 60-day history walk has finished, as
--                  api_overview's sync.pending reads it
--
-- Dropped from the mock on 2026-10-24, so gone from the triggers: grid_seen and
-- soc_overnight. api_alerts_due_raw is now a thin view over email_plant_events,
-- so the thresholds live in one place.
-- ============================================================================

create table if not exists public.email_sent (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  plant_id   bigint,
  kind       text not null,
  key        text not null,
  data       jsonb not null default '{}'::jsonb,
  sent_at    timestamptz not null default now(),
  closed_at  timestamptz,
  unique (user_id, key)
);
create index if not exists email_sent_open_idx on public.email_sent (kind) where closed_at is null;

create table if not exists public.email_outbox (
  id          bigint generated always as identity primary key,
  email       text not null,
  kind        text not null check (kind in ('account_deleted')),
  created_at  timestamptz not null default now()
);

alter table public.email_sent enable row level security;
alter table public.email_outbox enable row level security;
revoke all on public.email_sent, public.email_outbox from public, anon, authenticated;
grant all on public.email_sent, public.email_outbox to service_role;

-- Everyone here already has a plant and its history: no welcome, no "history synced".
insert into public.email_sent (user_id, kind, key, closed_at)
select id, 'welcome', 'welcome', now() from auth.users
on conflict (user_id, key) do nothing;
insert into public.email_sent (user_id, plant_id, kind, key, closed_at)
select user_id, plant_id, 'history', 'history:' || plant_id, now() from public.plant_users
on conflict (user_id, key) do nothing;

-- ---------------------------------------------------------------------------
-- Per-plant triggers
-- ---------------------------------------------------------------------------
create or replace function public.email_plant_events(p_plant bigint)
returns table (kind text, key text, data jsonb)
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  with
  pz as (select public.plant_tz(p_plant) as tz),
  now_s as (select extract(epoch from now())::bigint as t),
  cfg as (select coalesce((select has_grid from public.plant_config where plant_id = p_plant), true) as has_grid,
                 coalesce((select has_battery from public.plant_config where plant_id = p_plant), true) as has_battery,
                 (select battery_banks from public.plant_config where plant_id = p_plant) as banks),
  loc as (select public.today_tz((select tz from pz)) as day,
                 extract(hour from timezone((select tz from pz), now()))::int as hour),
  day_lo as (select public.day_start_epoch_tz((select day from loc), (select tz from pz)) as lo),

  -- Grid. Minutes where presence is unknown are skipped, as in 0057.
  grid_known as (
    select r.ts, public.q_grid_present(p_plant, r.ts) as present
      from (select distinct ts from public.readings, now_s where plant_id = p_plant and ts >= now_s.t - 1800) r
  ),
  gk as (select ts, present from grid_known where present is not null),
  grid as (
    select (select count(*) = 3 and bool_and(not present) from (select present from gk order by ts desc limit 3) x) as down,
           (select count(*) = 2 and bool_and(present) from (select present from gk order by ts desc limit 2) x) as up,
           (select max(ts) from gk where present) as last_on,
           (select max(ts) from gk where not present) as last_off
  ),

  -- Battery temperature: the hottest inverter at the newest reading.
  hot as (
    select r.ts, r.batt_temp_c as temp from public.readings r, now_s
     where r.plant_id = p_plant and r.ts >= now_s.t - 600 and r.batt_temp_c > 0 and r.batt_temp_c < 80
     order by r.ts desc, r.batt_temp_c desc limit 1
  ),

  -- Charge spread between inverters' batteries, minute by minute, over the last hour.
  bank as (
    select r.ts, max(r.batt_soc) - min(r.batt_soc) as spread
      from public.readings r, now_s
     where r.plant_id = p_plant and r.ts >= now_s.t - 3600 and r.batt_soc between 1 and 100
     group by r.ts
    having count(distinct r.sn) >= 2
  ),
  drift as (select count(*) >= 30 and max(ts) - min(ts) >= 3300 and min(spread) >= 10 as drifting, max(ts) as ts from bank),

  -- Strings: 0057's dead_held, bounded to the window.
  str_latest as (select max(ts) as ts from public.strings, now_s where plant_id = p_plant and ts >= now_s.t - 900),
  dead_held as (
    select s.sn, s.no from public.strings s, loc, now_s
     where s.plant_id = p_plant and loc.hour between 11 and 14 and s.ts >= now_s.t - 900
       and coalesce(s.volt_v, 0) < 1.5 and coalesce(s.power_w, 0) < 5
       and exists (select 1 from public.strings o where o.plant_id = p_plant and o.ts = s.ts and o.sn = s.sn and o.no is distinct from s.no and coalesce(o.power_w, 0) > 200)
     group by s.sn, s.no
    having count(*) >= 12
       and exists (select 1 from public.strings cur, str_latest where cur.plant_id = p_plant and cur.ts = str_latest.ts and cur.sn = s.sn and cur.no = s.no and coalesce(cur.volt_v, 0) < 1.5 and coalesce(cur.power_w, 0) < 5)
  ),
  dead1 as (
    select d.sn, d.no, coalesce(nullif(m.alias, ''), 'Inverter ' || d.sn) as inverter
      from dead_held d left join private.meta m on m.sn = d.sn
     order by m.ord nulls last, d.sn, d.no limit 1
  ),

  -- SunSynk's own clock: the newest device_time across the plant, read only from
  -- rows our polls wrote in the last 3 minutes. No such rows: our polls are failing,
  -- which is not the inverter going quiet, so no logger row at all.
  dev as (
    select max(extract(epoch from (r.device_time::timestamp at time zone (select tz from pz))))::bigint as last_dev
      from public.readings r, now_s
     where r.plant_id = p_plant and r.ts >= now_s.t - 180
       and r.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
  )

  select 'grid_down', 'grid_down:' || p_plant || ':' || x.since,
         jsonb_build_object('since', x.since, 'chargePct', x.soc)
    from (select (select min(ts) from gk where not present and ts > coalesce(grid.last_on, 0)) as since,
                 (select round(soc)::int from public.agg_minute a, now_s
                   where a.plant_id = p_plant and a.ts >= now_s.t - 600 and a.soc is not null order by a.ts desc limit 1) as soc
            from grid where grid.down) x, cfg
   where cfg.has_grid
  union all
  select 'grid_on', 'grid_on:' || p_plant,
         jsonb_build_object('since', (select min(ts) from gk where present and ts > coalesce(grid.last_off, 0)))
    from grid, cfg where grid.up and cfg.has_grid
  union all
  select 'batt_hot', 'batt_hot:' || p_plant || ':' || (select day from loc),
         jsonb_build_object('at', hot.ts, 'tempC', round(hot.temp)::int)
    from hot, cfg where hot.temp > 40 and cfg.has_battery
  union all
  select 'bank_drift', 'bank_drift:' || p_plant || ':' || (select day from loc),
         jsonb_build_object('banks', (
           select jsonb_agg(jsonb_build_object('name', coalesce(nullif(m.alias, ''), 'Inverter ' || r.sn), 'chargePct', round(r.batt_soc)::int)
                            order by m.ord nulls last, r.sn)
             from public.readings r left join private.meta m on m.sn = r.sn
            where r.plant_id = p_plant and r.ts = drift.ts and r.batt_soc between 1 and 100))
    from drift, cfg where drift.drifting and cfg.has_battery and cfg.banks is distinct from 'shared'
  union all
  select 'string_dead', 'string_dead:' || p_plant || ':' || (select day from loc),
         jsonb_build_object('string', 'String ' || dead1.no, 'inverter', dead1.inverter,
           -- the minute after it last had voltage today; 15 min ago when it never did
           'since', coalesce((select max(s.ts) + 60 from public.strings s, day_lo
                               where s.plant_id = p_plant and s.sn = dead1.sn and s.no = dead1.no
                                 and s.ts >= day_lo.lo and coalesce(s.volt_v, 0) >= 1.5),
                             (select t - 900 from now_s)))
    from dead1
  union all
  select 'logger_stale', 'logger_stale:' || p_plant || ':' || dev.last_dev, jsonb_build_object('since', dev.last_dev)
    from dev, now_s where now_s.t - dev.last_dev > 900
  union all
  select 'logger_ok', 'logger_ok:' || p_plant, jsonb_build_object('at', dev.last_dev)
    from dev, now_s where now_s.t - dev.last_dev <= 900
$$;

-- ---------------------------------------------------------------------------
-- SunSynk itself, across every login
-- ---------------------------------------------------------------------------
-- Days above 40 C in the last 30, today included, for the batt_hot email. Read
-- only when that email goes, not every minute the battery stays hot.
create or replace function public.email_hot_days(p_plant bigint)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(distinct (timezone(public.plant_tz(p_plant), to_timestamp(h.ts)))::date)::int
    from public.readings h
   where h.plant_id = p_plant and h.ts >= extract(epoch from now())::bigint - 30 * 86400
     and h.batt_temp_c > 40 and h.batt_temp_c < 80
$$;

create or replace function public.email_sunsynk_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  last_ok timestamptz;
  ran boolean := true;
begin
  select max(last_ok_at) into last_ok from private.sunsynk_accounts where status = 'active';
  if last_ok is null then return null; end if;
  -- Our own cron not running is not SunSynk being down. No pg_cron (the local
  -- stack): assume it ran.
  if to_regclass('cron.job_run_details') is not null then
    execute $q$
      select exists (select 1 from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                      where j.jobname = 'sunsynk-poll' and d.status = 'succeeded'
                        and d.start_time > now() - interval '3 minutes')$q$ into ran;
  end if;
  return jsonb_build_object(
    'since', extract(epoch from last_ok)::bigint,
    'down', ran and last_ok < now() - interval '10 minutes',
    'up', last_ok >= now() - interval '2 minutes');
end $$;

create or replace function public.email_relinks()
returns table (user_id uuid, account_id uuid, key text)
language sql
stable
security definer
set search_path = ''
as $$
  -- last_ok_at stops moving when a login dies, so it names this death; older
  -- deaths were before the sender existed.
  select a.user_id, a.id, 'needs_relink:' || a.id || ':' || extract(epoch from a.last_ok_at)::bigint
    from private.sunsynk_accounts a
   where a.status = 'needs_relink' and a.last_ok_at > now() - interval '2 days'
$$;

create or replace function public.email_users()
returns table (user_id uuid, email text, confirmed boolean, plant_id bigint, plant_name text,
               account_id uuid, linked_at timestamptz, tz text)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, u.email::text, u.email_confirmed_at is not null,
         pu.plant_id, pu.plant_name, pu.account_id, pu.linked_at,
         case when pu.plant_id is not null then public.plant_tz(pu.plant_id) else 'Africa/Johannesburg' end
    from auth.users u
    left join public.plant_users pu on pu.user_id = u.id
   where u.email is not null and u.deleted_at is null
   order by u.id, pu.linked_at
$$;

create or replace function public.email_history_done()
returns setof bigint
language sql
stable
security definer
set search_path = ''
as $$
  select c.plant_id from public.plant_config c
   where c.backfill_next is null
     and (c.temp_next is null or c.temp_next >= public.today_tz(coalesce(c.timezone, 'Africa/Johannesburg')))
$$;

revoke all on function public.email_plant_events(bigint), public.email_hot_days(bigint), public.email_sunsynk_state(), public.email_relinks(),
                       public.email_users(), public.email_history_done()
  from public, anon, authenticated;
grant execute on function public.email_plant_events(bigint), public.email_hot_days(bigint), public.email_sunsynk_state(), public.email_relinks(),
                          public.email_users(), public.email_history_done()
  to service_role;

-- ---------------------------------------------------------------------------
-- api_alerts_due_raw: the same events, in its old shape, without the dropped kinds
-- ---------------------------------------------------------------------------
create or replace function public.api_alerts_due_raw(p_plant bigint)
returns table (kind text, key text, level text, title text, body text, value double precision)
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  select e.kind, e.key, 'urgent',
         case e.kind when 'grid_down' then 'Grid is off' when 'batt_hot' then 'Battery is hot'
                     when 'bank_drift' then 'Batteries charging unevenly' when 'string_dead' then 'Some panels stopped producing'
                     when 'logger_stale' then 'No readings from SunSynk' end,
         '', null::double precision
    from public.email_plant_events(p_plant) e
   where e.kind in ('grid_down', 'batt_hot', 'bank_drift', 'string_dead', 'logger_stale')
$$;

-- ---------------------------------------------------------------------------
-- Delete my account: 0050's body, plus the address kept for "account deleted"
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

  -- notify sends "account deleted" to this address, then deletes the row (SOLAR-157)
  insert into public.email_outbox (email, kind)
  select email, 'account_deleted' from auth.users where id = uid and email is not null;

  delete from public.profiles where user_id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(array_length(orphans, 1), 0));
end $$;
revoke all on function public.api_account_delete() from public, anon;
grant execute on function public.api_account_delete() to authenticated;

-- ---------------------------------------------------------------------------
-- notify every minute. It sends nothing until the NOTIFY_LIVE secret is "1";
-- before that each run only works out what it would send. Production only, as 0030.
-- ---------------------------------------------------------------------------
do $$
declare
  fn_url text := 'https://pmakzojwhouamawgszrc.functions.supabase.co/notify';
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - skipping email-notify schedule (expected on the local stack)';
    return;
  end if;

  if exists (select 1 from cron.job where jobname = 'email-notify') then
    perform cron.unschedule('email-notify');
  end if;

  perform cron.schedule('email-notify', '* * * * *', format($job$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        'Content-Type', 'application/json'),
      body := '{}'::jsonb,
      timeout_milliseconds := 55000);
  $job$, fn_url));
end $$;

notify pgrst, 'reload schema';
