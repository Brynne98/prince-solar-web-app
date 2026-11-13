-- ============================================================================
-- 0199 — the free week belongs to the plant (SOLAR-547, decided by Brynne 2026-11-13).
--
-- Before (0121): one free week per account. A new account got a new week, full
-- history and a 60-day fetch on a plant that already had them: delete and sign up
-- again, or a second account on the same SunSynk login (cheating review 2026-11-12,
-- finding 1). A Free account also read the full history of a plant a paid account
-- holds, because the trim deletes per plant and reads had no limit (finding 4). An
-- account with no free-week row was never trimmed (finding 5).
--
-- Now:
--   - private.plant_week: one row per plant, the time its week started. No account,
--     name or login. It stays after an account delete.
--   - A link by a Free account starts the week of each plant that has none
--     (plant_users_upsert, so a password link, the hourly sync and a share claim).
--     A plant only paid accounts ever linked has no week yet.
--   - The account's own row (private.free_week_logins) is written in the same call,
--     for every account. It starts at the earliest week among the plants of the
--     account's first link: a join on day 3 has 4 days left; a plant whose week is
--     over gives a row at least 15 days back, so no free-week notice or email. The
--     notices, emails and api_me read that row as before.
--   - What a Free account reads: a plant's full history while that plant's 7 days
--     run, else the last 24 hours, the same rows the trim (0111) keeps. This holds
--     when a paid account holds the plant and its history is kept. The rule is in
--     one place, my_full_plant_ids / my_read_from. The row rules use it (a second,
--     restrictive rule on each data table), and so does each reader that skips the
--     row rules. A paid account, a comped account and a failed card's 30 days
--     (keep_until, 0146) read everything, as before.
--   - The trim and the 60-day fetch (free_trimmed_plants) go by the plant's week.
--     A plant with no week on record is trimmed.
--   - The account's row now goes with the account (it holds the SunSynk login name).
--
-- Not changed: ticks and the 90-day change stay per account (0197, 0198).
--
-- Existing rows: each plant's week is the earliest free-week row among its accounts.
-- A plant of a Free account with no row at all (linked before 0110) starts its week
-- today, so nothing is deleted at deploy.
-- ============================================================================

create table if not exists private.plant_week (
  plant_id   bigint primary key,
  started_at timestamptz not null default now()
);
alter table private.plant_week enable row level security;
revoke all on table private.plant_week from public, anon, authenticated;
grant all on table private.plant_week to service_role;

insert into private.plant_week (plant_id, started_at)
select pu.plant_id, min(f.started_at)
  from public.plant_users pu
  join private.free_week_logins f on f.user_id = pu.user_id
 group by pu.plant_id
on conflict (plant_id) do nothing;

insert into private.plant_week (plant_id)
select distinct pu.plant_id
  from public.plant_users pu
  left join private.billing b on b.user_id = pu.user_id
 where coalesce(b.plan, 'free') = 'free'
on conflict (plant_id) do nothing;

insert into private.free_week_logins (sunsynk_username, user_id)
select '', pu.user_id
  from public.plant_users pu
  left join private.billing b on b.user_id = pu.user_id
 where coalesce(b.plan, 'free') = 'free'
 group by pu.user_id
on conflict (user_id) do nothing;

-- The account's row holds its SunSynk login name: it goes with the account.
delete from private.free_week_logins f
 where not exists (select 1 from auth.users u where u.id = f.user_id);
alter table private.free_week_logins
  add constraint free_week_logins_user_fk foreign key (user_id) references auth.users (id) on delete cascade;

-- ---------------------------------------------------------------------------
-- The rule, once. The caller's running plants it may read in full: the account is
-- paid or comped, or inside a failed card's 30 days, or the plant's week runs.
-- ---------------------------------------------------------------------------
create or replace function public.my_full_plant_ids()
returns setof bigint
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select pu.plant_id
    from public.plant_users pu
   where pu.user_id = auth.uid() and not pu.paused
     and (exists (select 1 from private.billing b
                   where b.user_id = pu.user_id
                     and (b.plan <> 'free' or b.keep_until >= private.billing_today()))
          or exists (select 1 from private.plant_week w
                      where w.plant_id = pu.plant_id and w.started_at > now() - interval '7 days'))
$$;
revoke all on function public.my_full_plant_ids() from public, anon;
grant execute on function public.my_full_plant_ids() to authenticated, service_role;

-- The first second of a plant the caller may read: 0 (all of it), or 24 hours back.
-- The server (service_role, or no API request) reads everything, as in my_plant.
create or replace function public.my_read_from(p_plant bigint)
returns bigint
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select case when coalesce(auth.role(), 'service_role') = 'service_role'
                or p_plant in (select public.my_full_plant_ids()) then 0
              else extract(epoch from now() - interval '24 hours')::bigint end
$$;
revoke all on function public.my_read_from(bigint) from public, anon;
grant execute on function public.my_read_from(bigint) to authenticated, service_role;

-- Row rules: a second rule on each data table, on top of "the caller's plant".
-- It covers direct reads and every reader that runs as the caller.
do $$
declare t text;
begin
  foreach t in array array['readings', 'readings_5m', 'strings', 'strings_5m', 'agg_minute', 'agg_5m',
                           'inverter_history', 'inverter_history_5m'] loop
    execute format('drop policy if exists %I on public.%I', t || '_free_read', t);
    execute format($p$create policy %I on public.%I as restrictive for select to authenticated
      using (plant_id in (select public.my_full_plant_ids())
             or ts >= (select extract(epoch from now() - interval '24 hours')::bigint))$p$, t || '_free_read', t);
  end loop;
end $$;
drop policy if exists grid_off_free_read on public.grid_off;
create policy grid_off_free_read on public.grid_off as restrictive for select to authenticated
  using (plant_id in (select public.my_full_plant_ids())
         or ended_at is null or ended_at >= (select now() - interval '24 hours'));
-- day totals: today and yesterday, as the trim keeps (South Africa only)
drop policy if exists plant_energy_free_read on public.plant_energy;
create policy plant_energy_free_read on public.plant_energy as restrictive for select to authenticated
  using (plant_id in (select public.my_full_plant_ids())
         or (bucket = 'day' and period >= (select (now() at time zone 'Africa/Johannesburg')::date - 1)));

-- ---------------------------------------------------------------------------
-- 0182's trim list, by the plant's week: every account on the plant is Free with no
-- 30 days kept, and the plant's week is over (one hour past, so the day-7 report is
-- built first) or was never started.
-- ---------------------------------------------------------------------------
create or replace function public.free_trimmed_plants()
returns setof bigint
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select pu.plant_id
    from public.plant_users pu
    left join private.billing b on b.user_id = pu.user_id
   group by pu.plant_id
  having bool_and(coalesce(b.plan, 'free') = 'free'
                  and (b.keep_until is null or b.keep_until < private.billing_today()))
     and not exists (select 1 from private.plant_week w
                      where w.plant_id = pu.plant_id and w.started_at >= now() - interval '7 days 1 hour')
$$;

-- ---------------------------------------------------------------------------
-- 0197's upsert, with the week: for plants new to this account, a Free account
-- starts the week of each that has none, and the account's own row is written here,
-- in the same transaction as the link (it was a second call, sunsynk.ts).
-- ---------------------------------------------------------------------------
create or replace function public.plant_users_upsert(p_user uuid, p_account uuid, p_rows jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $$
declare
  p bigint;
  ids bigint[] := array(select (r->>'plant_id')::bigint from jsonb_array_elements(p_rows) r);
  login boolean;
  who text;
  fresh bigint[];
begin
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (0170)
  perform private.billing_lock(p_user);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for p in select distinct x from unnest(ids) x order by 1 loop
    perform pg_advisory_xact_lock(p);
  end loop;
  select kind = 'login', sunsynk_username into login, who from private.sunsynk_accounts where id = p_account and status <> 'disabled';
  if not found then
    raise exception 'plant_users_upsert: account % is removed or disabled', p_account;
  end if;
  for p in
    select g.plant_id from private.plant_purge g
     where g.plant_id = any (ids)
     order by g.plant_id
  loop
    raise notice 'plant % relinked while waiting to be purged: wiping first (%)', p, private.purge_plant(p);
  end loop;

  fresh := array(select distinct x from unnest(ids) x
                  where not exists (select 1 from public.plant_users where user_id = p_user and plant_id = x));

  if login and cardinality(ids) = 1
     and not exists (select 1 from public.plant_users where user_id = p_user and plant_id = ids[1]) then
    perform private.plant_pick_add(p_user, ids[1], p_rows->0->>'plant_name');
  end if;

  insert into public.plant_users (plant_id, user_id, account_id, plant_name)
  select (r->>'plant_id')::bigint, p_user, p_account, r->>'plant_name'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id, user_id) do update
    set account_id = excluded.account_id, plant_name = excluded.plant_name;

  if cardinality(fresh) > 0 then
    if coalesce((select plan from private.billing where user_id = p_user), 'free') = 'free' then
      insert into private.plant_week (plant_id) select x from unnest(fresh) x
      on conflict (plant_id) do nothing;
    end if;
    -- A week that is over when the account joins is written at least 15 days back: the
    -- account never had it, so the "ended" notice (day 7 to 14, 0148) stays away too.
    insert into private.free_week_logins (sunsynk_username, user_id, started_at)
    select lower(coalesce(who, '')), p_user,
           case when w.s > now() - interval '7 days' then w.s
                else least(w.s, now() - interval '15 days') end
      from (select coalesce(min(started_at), now()) as s from private.plant_week where plant_id = any (fresh)) w
    on conflict (user_id) do nothing;
  end if;

  if login and cardinality(ids) > 0 then
    update public.plant_users set share_missing_at = null, share_gone_at = null
     where account_id = p_account and user_id = p_user and not via_share and plant_id = any (ids)
       and (share_missing_at is not null or share_gone_at is not null);
    -- gone: not read any more; its owner is told once what can be done
    with g as (
      update public.plant_users set share_gone_at = now()
       where account_id = p_account and user_id = p_user and not via_share and share_gone_at is null
         and share_missing_at < now() - interval '50 minutes' and plant_id <> all (ids)
      returning user_id, plant_id, plant_name)
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    select g.user_id, g.plant_id, 'plant_off_login', 'plant_off_login:' || g.plant_id || ':' || extract(epoch from now())::bigint,
           jsonb_build_object('plants', jsonb_build_array(coalesce(g.plant_name, 'Plant ' || g.plant_id)), 'login', who), 1
      from g
    on conflict do nothing;
    update public.plant_users set share_missing_at = now()
     where account_id = p_account and user_id = p_user and not via_share and share_gone_at is null
       and share_missing_at is null and plant_id <> all (ids);
  end if;

  insert into public.app_config (key, value, note)
  select 'CALIBRATION_PLANT', (r->>'plant_id')::bigint,
         'the one plant the single-site forecast/alerts are bound to; set by the first link, then fixed'
    from jsonb_array_elements(p_rows) r
   order by (r->>'plant_id')::bigint
   limit 1
  on conflict (key) do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- The readers that skip the row rules (security definer) and the two day helpers
-- they call. Each body is the one before 0199 with the my_read_from limit added.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.q_day_agg(p_plant bigint, p_day date, p_source text DEFAULT NULL::text)
 RETURNS TABLE(hm text, pv_w numeric, load_w numeric, batt_w numeric, grid_w numeric, soc numeric, feed_n bigint, row_n bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pz as (select public.plant_tz(p_plant) as tz),
  b as (select public.day_start_epoch_tz(p_day, (select tz from pz)) as lo, public.my_read_from(p_plant) as rf),
  m as (
    select (a.ts - b.lo) / 300 as k,
           min(a.ts) as t,
           round(avg(a.pv_w)::numeric)   as pv_w,
           round(avg(a.load_w)::numeric) as load_w,
           round(avg(a.batt_w)::numeric) as batt_w,
           round(avg(a.grid_w)::numeric) as grid_w,
           round(avg(a.soc)::numeric)    as soc,
           sum(case when coalesce(a.source, 'poller') <> 'poller' then 1 else 0 end) as feed_n,
           count(*) as row_n
      from public.agg_minute a, b
     where a.plant_id = p_plant
       and a.ts >= b.lo and a.ts < b.lo + 86400 and a.ts >= b.rf
       and (p_source is null or a.source = p_source)
     group by (a.ts - b.lo) / 300
  ),
  f as (
    select (f.ts - b.lo) / 300 as k, f.ts as t,
           round(f.pv_w_avg::numeric), round(f.load_w_avg::numeric), round(f.batt_w_avg::numeric),
           round(f.grid_w_avg::numeric), round(f.soc_avg::numeric),
           (f.n - f.n_poller)::bigint, f.n::bigint
      from public.agg_5m f, b
     where f.plant_id = p_plant
       and f.ts >= b.lo and f.ts < b.lo + 86400 and f.ts >= b.rf
       and p_source is null          -- a 5-minute row mixes sources; every caller passes null
       and not exists (select 1 from m where m.k = (f.ts - b.lo) / 300)
  )
  select to_char(public.local_ts_tz(x.t, (select tz from pz)), 'HH24:MI'),
         x.pv_w, x.load_w, x.batt_w, x.grid_w, x.soc, x.feed_n, x.row_n
    from (select * from m union all select * from f) x
   order by x.t
$function$;

CREATE OR REPLACE FUNCTION public._plant_day_energy(p_plant bigint, p_from date, p_to date)
 RETURNS TABLE(period date, pv_kwh double precision, load_kwh double precision, imp_kwh double precision, exp_kwh double precision, chg_kwh double precision, dischg_kwh double precision)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with tz as (select public.plant_tz(p_plant) as z, public.my_read_from(p_plant) as rf),
  fin as (
    select e.period, e.pv_kwh, e.load_kwh, e.imp_kwh, e.exp_kwh, e.chg_kwh, e.dischg_kwh
      from public.plant_energy e, tz
     where e.plant_id = p_plant and e.bucket = 'day'
       and e.period between p_from and p_to
       and e.pv_kwh is not null
       and (tz.rf = 0 or e.period >= public.today_tz(tz.z) - 1)   -- what the trim keeps (0111)
       and e.synced_at >= to_timestamp(public.day_start_epoch_tz((e.period + 1)::date, tz.z))
  ),
  -- days the cache cannot answer for, within a fortnight of the window's end: today,
  -- yesterday before the sync, and any day a sync outage skipped. Older days with no
  -- finished row stay absent, as they were before 0058.
  gaps as (
    select g::date as period, tz.z as z
      from tz, generate_series(greatest(p_from, (p_to - 14)::date), p_to, interval '1 day') g
     where not exists (select 1 from fin f where f.period = g::date)
  ),
  gapr as (
    select period,
           public.day_start_epoch_tz(period, z) as lo,
           public.day_start_epoch_tz((period + 1)::date, z) as hi
      from gaps
  ),
  -- one index range per gap day, and an outer bound as well so the planner sees a single
  -- narrow window over agg_minute rather than an unbounded scan per day
  live as (
    select r.period,
           sum(m.pv_w) / 60000.0 as pv_kwh, sum(m.load_w) / 60000.0 as load_kwh,
           sum(greatest(m.grid_w, 0)) / 60000.0 as imp_kwh,
           sum(greatest(-m.grid_w, 0)) / 60000.0 as exp_kwh,
           sum(greatest(m.batt_w, 0)) / 60000.0 as chg_kwh,
           sum(greatest(-m.batt_w, 0)) / 60000.0 as dischg_kwh
      from gapr r
      join public.agg_minute m
        on m.plant_id = p_plant and m.ts >= r.lo and m.ts < r.hi
     where m.ts >= (select min(lo) from gapr) and m.ts < (select max(hi) from gapr) and m.ts >= (select rf from tz)
     group by r.period
  )
  select * from fin
  union all
  select * from live
$function$;

CREATE OR REPLACE FUNCTION public.api_balance(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  now_s as (select extract(epoch from now())::bigint as t),
  -- newest first, take one: max(ts) read every month of readings, because the plant id
  -- comes from pl and the planner can't use the index to stop early (SOLAR-35)
  latest_ts as (select (select ts from public.readings where plant_id = (select id from pl) and batt_soc is not null order by ts desc limit 1) as ts),
  -- one shared pack counts as one bank however many inverters read it (0042)
  nbanks as (select case when (select battery_banks from public.plant_config where plant_id = (select id from pl)) = 'shared' then least(1, count(distinct r.sn)) else count(distinct r.sn) end as n
               from public.readings r, latest_ts where r.plant_id = (select id from pl) and r.ts = latest_ts.ts and r.batt_soc between 1 and 100),
  bal as (
    select r.ts, max(r.batt_soc) - min(r.batt_soc) as socspread, max(r.batt_voltage_v) - min(r.batt_voltage_v) as vspread
      from public.readings r, now_s
     where r.plant_id = (select id from pl) and r.ts >= now_s.t - 72 * 3600 and r.ts >= (select public.my_read_from((select id from pl)))
       and r.batt_soc is not null and r.batt_soc between 1 and 100
     group by r.ts
    having count(distinct r.sn) >= 2 and (max(r.batt_soc) - min(r.batt_soc)) <= 25
  ),
  last_r as (select * from bal order by ts desc limit 1),
  win as (select count(*) >= 2 and (max(ts) - min(ts)) >= 9 * 60 as have_window, min(socspread) as min_spread from bal, now_s where bal.ts >= now_s.t - 600),
  spreads as (select (select round(socspread * 10) / 10 from last_r) as soc_spread, (select round(vspread * 100) / 100 from last_r) as v_spread),
  st as (
    select case when (select n from nbanks) < 2 then 'single'
                when s.soc_spread is null then 'unknown'
                when not coalesce(w.have_window, false) then 'balanced'
                when w.min_spread >= 5 then 'drifting' when w.min_spread >= 3 then 'watch' else 'balanced' end as status,
           case when (select n from nbanks) < 2 then 'single'
                when s.soc_spread is null then 'unknown'
                when s.soc_spread < 3 then 'balanced' when s.soc_spread < 5 then 'watch' else 'drifting' end as live_band,
           s.soc_spread, s.v_spread
      from spreads s, win w
  ),
  today_lo as (select public.day_start_epoch_tz(public.today_tz((select tz from pz)), (select tz from pz)) as lo),
  health as (
    select (select batt_temp_c from public.readings where plant_id = (select id from pl) and batt_temp_c > 0 and batt_temp_c < 80 order by ts desc limit 1) as temp_c,
           (select coalesce(round(sum(case when soc >= 98 then 1 else 0 end) / 60.0, 1), 0)
              from public.agg_minute, today_lo where plant_id = (select id from pl) and ts >= today_lo.lo and ts < today_lo.lo + 86400) as hrs_full
  )
  select jsonb_build_object(
    'banks', coalesce((select jsonb_agg(jsonb_build_object('sn', r.sn, 'soc', r.batt_soc, 'voltage', r.batt_voltage_v, 'current', r.batt_current_a) order by r.sn)
              from public.readings r, latest_ts where r.plant_id = (select id from pl) and r.ts = latest_ts.ts), '[]'::jsonb),
    'bankCount', (select n from nbanks),
    'socSpread', st.soc_spread, 'vSpread', st.v_spread, 'status', st.status,
    'pending', st.live_band not in ('unknown', 'balanced', 'single') and st.status = 'balanced',
    'max24h', (select round(max(socspread) * 10) / 10 from bal, now_s where bal.ts >= now_s.t - 24 * 3600),
    'max72h', (select round(max(socspread) * 10) / 10 from bal),
    'samples', (select count(*) from bal),
    'tempC', h.temp_c, 'hrsAtFullToday', h.hrs_full,
    'tempHot', h.temp_c is not null and h.temp_c > 35,
    'stale', (select ts from latest_ts) is null or ((select t from now_s) - (select ts from latest_ts)) > 600)
  from st, health h
$function$;

CREATE OR REPLACE FUNCTION public.api_data_days(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  tz as (select public.plant_tz((select id from pl)) as tz),
  b as (
    select a.ts / 300 as k from public.agg_minute a where a.plant_id = (select id from pl) and a.ts >= (select public.my_read_from((select id from pl)))
    union
    select f.ts / 300 from public.agg_5m f where f.plant_id = (select id from pl) and f.ts >= (select public.my_read_from((select id from pl)))
  ),
  days as (
    select distinct public.local_ts_tz(b.k * 300, (select tz from tz))::date as d from b
  )
  select coalesce(jsonb_agg(to_char(d, 'YYYY-MM-DD') order by d), '[]'::jsonb) from days
$function$;

CREATE OR REPLACE FUNCTION public.api_export(p_from date, p_to date, p_plant bigint DEFAULT NULL::bigint)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  pid bigint := public.my_plant(p_plant);
  tz  text;
  lo  bigint;
  hi  bigint;
  body text;
begin
  if pid is null then
    raise exception 'no plant' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'bad range' using errcode = '22023';
  end if;
  if p_to - p_from > 365 then
    raise exception 'range too long' using errcode = '22023';
  end if;

  tz := public.plant_tz(pid);
  lo := greatest(public.day_start_epoch_tz(p_from, tz), public.my_read_from(pid));
  hi := public.day_start_epoch_tz(p_to + 1, tz);

  with m as (
    select a.ts, a.pv_w::numeric as pv, a.load_w::numeric as home,
           greatest(a.grid_w, 0)::numeric as grid,
           greatest(a.batt_w, 0)::numeric as chg, greatest(-a.batt_w, 0)::numeric as dis,
           a.soc::numeric as soc
      from public.agg_minute a
     where a.plant_id = pid and a.ts >= lo and a.ts < hi
  ),
  mb as (select distinct (m.ts / 300) * 300 as b from m),
  f as (
    select f.ts, f.pv_w_avg::numeric, f.load_w_avg::numeric, f.grid_in_w_avg::numeric,
           f.batt_pos_w_avg::numeric, f.batt_neg_w_avg::numeric, f.soc_avg::numeric
      from public.agg_5m f
     where f.plant_id = pid and f.ts >= lo and f.ts < hi
       and not exists (select 1 from mb where mb.b = f.ts)
  ),
  x as (select * from m union all select * from f)
  select string_agg(
           -- not concat_ws: it drops a null and shifts the columns left
           to_char(public.local_ts_tz(x.ts, tz), 'YYYY-MM-DD HH24:MI')
             || ',' || coalesce(round(x.pv)::text, '') || ',' || coalesce(round(x.home)::text, '')
             || ',' || coalesce(round(x.grid)::text, '') || ',' || coalesce(round(x.chg)::text, '')
             || ',' || coalesce(round(x.dis)::text, '') || ',' || coalesce(round(x.soc)::text, ''),
           e'\n' order by x.ts)
    into body
    from x;

  return 'Time,Solar (W),Home (W),From grid (W),Battery charging (W),Battery discharging (W),Battery (%)'
         || e'\n' || coalesce(body || e'\n', '');
end $function$;

CREATE OR REPLACE FUNCTION public.api_grid_today(p_plant bigint DEFAULT NULL::bigint, p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with p as (select public.my_plant(p_plant) as id),
  z as (
    select p.id, coalesce((select c.timezone from public.plant_config c where c.plant_id = p.id),
                          'Africa/Johannesburg') as tz
      from p
  ),
  lo as (
    select z.id, public.my_read_from(z.id) as rf,
           extract(epoch from coalesce(p_date, (now() at time zone z.tz)::date)::timestamp at time zone z.tz)::bigint as t0,
           least(extract(epoch from (coalesce(p_date, (now() at time zone z.tz)::date) + 1)::timestamp at time zone z.tz)::bigint,
                 extract(epoch from now())::bigint + 60) as t1
      from z
  ),
  m as (
    select g.ts, g.present
      from lo, private.grid_minutes(lo.id, greatest(lo.t0, lo.rf), lo.t1) g
  ),
  v as (
    select ((r.ts - lo.t0) / 300)::int as b,
           avg(r.grid_volt_v) filter (where r.grid_volt_v > 100) as volt
      from lo join public.readings r on r.plant_id = lo.id and r.ts >= lo.t0 and r.ts < lo.t1 and r.ts >= lo.rf
     group by 1
  ),
  o as (
    select ((m.ts - lo.t0) / 300)::int as b, bool_or(not m.present) as off
      from m, lo
     group by 1
  )
  select jsonb_build_object(
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'i', coalesce(v.b, o.b),
               'v', round(v.volt::numeric, 1),
               'off', coalesce(o.off, false))
             order by coalesce(v.b, o.b))
        from v full join o on o.b = v.b), '[]'::jsonb),
    'offMinutes', (select count(*) from m where not m.present),
    'asOf', extract(epoch from now())::bigint                                    -- 0167
  )
$function$;

CREATE OR REPLACE FUNCTION public.api_inverter_history(p_date date DEFAULT NULL::date, p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  pz as (select public.plant_tz((select id from pl)) as tz),
  d as (select coalesce(p_date, public.today_tz((select tz from pz))) as day),
  lo as (select public.day_start_epoch_tz((select day from d), (select tz from pz)) as t0, public.my_read_from((select id from pl)) as rf),
  raw as (
    select t.sn, ((t.ts - (select t0 from lo)) / 300)::int as bkt, t.ts, t.ac_c, t.dc_c, t.vac_v, t.fac_hz, t.grid_fac_hz
      from public.inverter_history t, lo
     where t.plant_id = (select id from pl) and t.ts >= lo.t0 and t.ts < lo.t0 + 86400 and t.ts >= lo.rf
  ),
  fromraw as (
    select sn, bkt, count(*)::int as n, count(dc_c)::int as dcn,
           max(ac_c) as ac, max(dc_c) as dc, min(dc_c) as dcmin,
           min(vac_v) as vmin, max(vac_v) as vmax,
           (array_agg(vac_v order by ts desc) filter (where vac_v is not null))[1] as v,
           min(fac_hz) as fmin, max(fac_hz) as fmax,
           min(grid_fac_hz) as gmin, max(grid_fac_hz) as gmax
      from raw group by sn, bkt
  ),
  b as (
    select * from fromraw
    union all
    select f.sn, ((f.ts - (select t0 from lo)) / 300)::int, f.n::int, case when f.dc_max is null then 0 else f.n::int end,
           f.ac_max, f.dc_max, f.dc_min, f.vac_min, f.vac_max, f.vac_last,
           f.fac_min, f.fac_max, f.gfac_min, f.gfac_max
      from public.inverter_history_5m f, lo
     where f.plant_id = (select id from pl) and f.ts >= lo.t0 and f.ts < lo.t0 + 86400 and f.ts >= lo.rf
       and not exists (select 1 from fromraw r
                        where r.sn = f.sn and r.bkt = ((f.ts - lo.t0) / 300)::int)
  ),
  sns as (
    select r.sn, coalesce(nullif(m.alias, ''), r.sn) as alias
      from (select distinct sn from b) r left join private.meta m on m.sn = r.sn
  )
  select jsonb_build_object(
    'date', (select day from d)::text,
    'inverters', coalesce((select jsonb_agg(jsonb_build_object(
        'sn', s.sn, 'alias', s.alias,
        'dcFlat', (select sum(x.dcn) > 1 and min(x.dcmin) = max(x.dc) from b x where x.sn = s.sn),
        'last', (select public._hm(max(bkt)) from b x where x.sn = s.sn),
        'points', (select jsonb_agg(jsonb_build_object('time', public._hm(g.i),
                     'ac', x.ac, 'dc', x.dc, 'vmin', x.vmin, 'vmax', x.vmax, 'v', x.v,
                     'fmin', x.fmin, 'fmax', x.fmax, 'gmin', x.gmin, 'gmax', x.gmax) order by g.i)
                     from generate_series(0, 287) g(i) left join b x on x.sn = s.sn and x.bkt = g.i)
      ) order by s.alias) from sns s), '[]'::jsonb))
$function$;

CREATE OR REPLACE FUNCTION public.api_plant_days(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  -- plant and day bounds as variables: planned with fixed values, the
  -- (plant_id, ts) keys are used rather than a walk of the ts index
  v_plant bigint := public.my_plant(p_plant);
  v_tz    text   := public.plant_tz(v_plant);
  v_today date   := public.today_tz(v_tz);
  v_lo    bigint := public.day_start_epoch_tz(v_today - 60, v_tz);
  v_days  bigint;
  v_rf    bigint := public.my_read_from(v_plant);
begin
  if exists (select 1 from public.agg_minute where plant_id = v_plant and ts < v_lo and ts >= v_rf)
     or exists (select 1 from public.agg_5m where plant_id = v_plant and ts < v_lo and ts >= v_rf) then
    return jsonb_build_object('days', 61);
  end if;
  select count(*) into v_days
    from generate_series(0, 60) g(i)
   where exists (select 1 from public.agg_minute a
                  where a.plant_id = v_plant
                    and a.ts >= public.day_start_epoch_tz(v_today - g.i, v_tz)
                    and a.ts <  public.day_start_epoch_tz(v_today - g.i, v_tz) + 86400 and a.ts >= v_rf)
      or exists (select 1 from public.agg_5m f
                  where f.plant_id = v_plant
                    and f.ts >= public.day_start_epoch_tz(v_today - g.i, v_tz)
                    and f.ts <  public.day_start_epoch_tz(v_today - g.i, v_tz) + 86400 and f.ts >= v_rf);
  return jsonb_build_object('days', v_days);
end $function$;

CREATE OR REPLACE FUNCTION public.api_string_health(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  z as (select public.plant_tz((select id from pl)) as tz, public.my_read_from((select id from pl)) as rf),
  t as (
    select public.day_start_epoch_tz(public.today_tz((select tz from z)), (select tz from z)) as t0,
           extract(epoch from now())::bigint as nw
  ),
  w as (select greatest((select nw from t) - (select t0 from t), 60) as len),
  days as (
    select g as k, public.day_start_epoch_tz(public.today_tz((select tz from z)) - g, (select tz from z)) as d0
      from generate_series(0, 14) g
  ),
  used as (
    select st.sn, st.no
      from public.strings st
     where st.plant_id = (select id from pl)
       and st.ts >= (select d0 from days where k = 14) and st.ts >= (select rf from z)
       and st.power_w >= 50
     group by st.sn, st.no
  ),
  s as (
    select d.k, x.sn, x.no, x.kwh
      from days d
      cross join lateral (
        select st.sn, st.no, sum(greatest(st.power_w, 0)) / 60000.0 as kwh
          from public.strings st
         where st.plant_id = (select id from pl)
           and st.ts >= d.d0 and st.ts < d.d0 + (select len from w) and st.ts >= (select rf from z)
         group by st.sn, st.no
      ) x
      join used u on u.sn = x.sn and u.no = x.no
  ),
  tot as (
    select k, sn, kwh,
           sum(kwh) over (partition by k, sn) as inv_kwh,
           sum(kwh) over (partition by k) as plant_kwh,
           no
      from s
  ),
  shares as (
    select k, sn, no, kwh, plant_kwh,
           case when inv_kwh > 0 then kwh / inv_kwh end as inv_share,
           case when plant_kwh > 0 then kwh / plant_kwh end as plant_share
      from tot
  ),
  usual as (
    select sn, no, avg(inv_share) as inv_share, avg(plant_share) as plant_share
      from shares
     where k between 1 and 14 and plant_kwh > 1
     group by sn, no
  ),
  hist as (
    select count(distinct k) as n from shares where k between 1 and 14 and plant_kwh > 1
  ),
  batt as (
    select r.sn, max(r.batt_soc) >= 98 as full
      from public.readings r
     where r.plant_id = (select id from pl) and r.ts >= (select t0 from t)
     group by r.sn
  ),
  last as (
    select st.sn, max(st.ts) as ts
      from public.strings st
     where st.plant_id = (select id from pl) and st.ts >= (select t0 from t)
     group by st.sn
  ),
  inv as (
    select u.sn,
           jsonb_agg(jsonb_build_object(
             'no', u.no,
             'todayKwh', round(coalesce(td.kwh, 0)::numeric, 2),
             'todayInvShare', round(td.inv_share::numeric, 4),
             'todayPlantShare', round(td.plant_share::numeric, 4),
             'usualInvShare', round(us.inv_share::numeric, 4),
             'usualPlantShare', round(us.plant_share::numeric, 4)) order by u.no) as strings
      from used u
      left join shares td on td.k = 0 and td.sn = u.sn and td.no = u.no
      left join usual us on us.sn = u.sn and us.no = u.no
     group by u.sn
  )
  select jsonb_build_object(
    'historyDays', (select n from hist),
    'todayKwh', round(coalesce((select max(plant_kwh) from shares where k = 0), 0)::numeric, 2),
    'inverters', coalesce((select jsonb_agg(jsonb_build_object(
        'sn', i.sn,
        'battFull', coalesce(b.full, false),
        'lastTs', l.ts,
        'strings', i.strings) order by i.sn)
      from inv i left join batt b on b.sn = i.sn left join last l on l.sn = i.sn), '[]'::jsonb))
$function$;

CREATE OR REPLACE FUNCTION public.api_trends_compare(p_plant bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  with pl as (select public.my_plant(p_plant) as id),
  tz as (select public.plant_tz((select id from pl)) as tz, public.my_read_from((select id from pl)) as rf),
  t as (select public.today_tz((select tz from tz)) as d),
  b as (
    select d,
           date_trunc('week', d)::date  as week_start,
           date_trunc('month', d)::date as month_start,
           date_trunc('year', d)::date  as year_start
      from t
  ),
  -- same day number last month, null when last month has no such day
  lastm as (
    select g::date as cur,
           case when extract(day from (date_trunc('month', g) - interval '1 month' + (extract(day from g)::int - 1) * interval '1 day'))::int
                     = extract(day from g)::int
                then (date_trunc('month', g) - interval '1 month' + (extract(day from g)::int - 1) * interval '1 day')::date end as prev
      from b, generate_series(b.month_start, b.d, interval '1 day') g
  ),
  -- finished current-slice days with the previous-period day each is paired to
  pairs as (
    select 'week' as k, g::date as cur, (g - interval '7 days')::date as prev
      from b, generate_series(b.week_start, b.d - 1, interval '1 day') g
    union all
    select 'month', cur, prev from lastm, b where cur < b.d
    union all
    -- same date last year; 29 Feb pairs with nothing
    select 'year', g::date,
           case when (g - interval '1 year') + interval '1 year' = g then (g - interval '1 year')::date end
      from b, generate_series(b.year_start, b.d - 1, interval '1 day') g
  ),
  span as (
    select min(least(cur, coalesce(prev, cur))) as lo,
           max(greatest(cur, coalesce(prev, cur))) as hi
      from pairs
  ),
  e as (select * from public._plant_day_energy((select id from pl), (select lo from span), (select hi from span))),
  matched as (
    select p.k, p.cur, p.prev,
           c.pv_kwh as c_pv, c.load_kwh as c_load, c.imp_kwh as c_imp,
           v.pv_kwh as p_pv, v.load_kwh as p_load, v.imp_kwh as p_imp
      from pairs p
      join e c on c.period = p.cur
      join e v on v.period = p.prev
  ),
  -- every period gets a row, even on its first day when no finished day pairs yet
  spans as (
    select ks.k, count(p.cur) as span
      from (values ('week'), ('month'), ('year')) ks(k) left join pairs p on p.k = ks.k
     group by ks.k
  ),
  sums as (
    select s.k,
           jsonb_build_object(
             'cur',  jsonb_build_object('pv', coalesce(round(sum(m.c_pv)::numeric, 1), 0), 'load', coalesce(round(sum(m.c_load)::numeric, 1), 0), 'imp', coalesce(round(sum(m.c_imp)::numeric, 1), 0)),
             'prev', jsonb_build_object('pv', coalesce(round(sum(m.p_pv)::numeric, 1), 0), 'load', coalesce(round(sum(m.p_load)::numeric, 1), 0), 'imp', coalesce(round(sum(m.p_imp)::numeric, 1), 0)),
             'days', count(m.cur),
             'span', s.span) as v
      from spans s left join matched m on m.k = s.k
     group by s.k, s.span
  ),
  -- ---- today so far, and the day it pairs with up to the same time ----
  tlo as (select public.day_start_epoch_tz(b.d, (select tz from tz)) as lo from b),
  -- today's latest poll, the one the tiles show; it must be today's
  latest as (
    select r.ts from public.readings r, tlo
     where r.plant_id = (select id from pl) and r.ts >= tlo.lo
     order by r.ts desc limit 1
  ),
  -- today's latest poll as a local clock time; each matching day is read at that clock time
  el as (select (to_timestamp(latest.ts) at time zone (select tz from tz))::time as t from latest),
  tpairs as (
    select 'today' as k, (b.d - 1) as prev from b
    union all select 'week', (b.d - 7) from b
    union all select 'month', (select prev from lastm, b where lastm.cur = b.d)
    union all select 'year', case when (b.d - interval '1 year') + interval '1 year' = b.d then (b.d - interval '1 year')::date end from b
  ),
  tc as (
    select p.k, p.prev, x.lo, extract(epoch from ((p.prev + el.t) at time zone (select tz from tz)))::bigint as cut
      from tpairs p, el,
           lateral (select public.day_start_epoch_tz(p.prev, (select tz from tz)) as lo) x
     where p.prev is not null
  ),
  -- each inverter in today's poll: its last good reading on the matching day at or
  -- before the moment, from readings, else the 5-minute history (counters as at the
  -- bucket's end). One index probe per inverter per pair.
  inv as (select r.sn from public.readings r, latest where r.plant_id = (select id from pl) and r.ts = latest.ts),
  per as (
    select tc.k, i.sn,
           coalesce(x.pv, y.pv) as pv, coalesce(x.load, y.load) as load, coalesce(x.imp, y.imp) as imp,
           (x.ts is not null or y.ts is not null) as found
      from tc cross join inv i
      left join lateral (
        select r.ts, r.pv_today_kwh as pv, r.load_today_kwh as load, r.grid_import_today_kwh as imp
          from public.readings r
         where r.sn = i.sn and r.plant_id = (select id from pl)
           and r.ts >= tc.lo and r.ts <= tc.cut and r.ts >= (select rf from tz) and r.device_time is not null
         order by r.ts desc limit 1) x on true
      left join lateral (
        select f.ts, f.pv_today_kwh as pv, f.load_today_kwh as load, f.grid_import_today_kwh as imp
          from public.readings_5m f
         where x.ts is null
           and f.plant_id = (select id from pl) and f.sn = i.sn
           and f.ts >= tc.lo and f.ts <= tc.cut - 300 and f.ts >= (select rf from tz) and f.pv_today_kwh is not null
         order by f.ts desc limit 1) y on true
  ),
  ctr as (
    select k, sum(pv) as pv, sum(load) as load, sum(imp) as imp
      from per group by k
    having bool_and(found)
  ),
  ig as (
    select tc.k,
           coalesce(sum(case when a.grid_w > 0 then a.grid_w * (5.0/60) / 1000 else 0 end), 0) as imp,
           count(a.hm) as n
      from tc left join lateral (
        select q.hm, q.grid_w from public.q_day_agg((select id from pl), tc.prev, null) q
         where q.hm <= to_char(public.local_ts_tz(tc.cut, (select tz from tz)), 'HH24:MI')) a on true
     group by tc.k
  ),
  nowv as (
    select c.k, jsonb_build_object(
             'pv',   coalesce(round(c.pv::numeric, 1), 0),
             'load', coalesce(round(c.load::numeric, 1), 0),
             'imp',  coalesce(round((case when g.n > 5 then g.imp else c.imp end)::numeric, 1), 0)) as v
      from ctr c join ig g on g.k = c.k
  )
  select coalesce((select jsonb_object_agg(s.k, s.v || jsonb_build_object('now', (select v from nowv where nowv.k = s.k))) from sums s), '{}'::jsonb)
         || jsonb_build_object('today', jsonb_build_object(
              'cur',  jsonb_build_object('pv', 0, 'load', 0, 'imp', 0),
              'prev', coalesce((select v from nowv where k = 'today'), jsonb_build_object('pv', 0, 'load', 0, 'imp', 0)),
              'days', case when exists (select 1 from nowv where k = 'today') then 1 else 0 end,
              'span', 1))
$function$;

notify pgrst, 'reload schema';
