-- ============================================================================
-- 0124 — Notifications in the app, and pop-ups (SOLAR-244).
--
-- The alerts already queued for email (0102) are the list: one email_queue row per
-- user per alert, written when it happens, kept whether or not the email went
-- (a switched-off email is status 'skipped'). Nothing new decides what an alert is.
--
--   email_queue.read_at     the user opened it, or marked all read.
--   email_queue.pushed_at   the pop-up pass has dealt with it. push_skip says why
--                           nothing was sent (switched off, no device, too old, its
--                           "down" had no pop-up). Rows from before this are marked
--                           done, so nothing old pops up.
--   push_subs               one row per browser (later: per phone) that turned
--                           pop-ups on. platform 'expo' is for the coming phone apps.
--   push_prefs              the five alert switches for pop-ups, as email_prefs has
--                           for email. No row = all on.
--
-- For the app (signed in):
--   api_notifications()            {pinned: [], items, unread}: the last 30 days, plants
--                                  still linked. pinned stays empty until SOLAR-212.
--   api_notifications_read(ids)    marks those read; null marks every one read.
--   api_push_sub(...) / api_push_unsub(endpoint)
-- For notify (service role):
--   push_claim(limit)   alerts due a pop-up with their text and devices, marked done.
--                       A "back" goes only when its "down" had a pop-up, and waits
--                       until the "down" has been dealt with.
--   push_done(ok, gone) last_ok_at on devices that took it; deletes the gone ones.
--
-- Titles and lines are written here once (private.alert_text) so the list, the
-- pop-up and the phone apps read the same words. Same facts as the emails
-- (plantEvent in _shared/email.ts), shorter.
-- ============================================================================

alter table public.email_queue
  add column if not exists read_at   timestamptz,
  add column if not exists pushed_at timestamptz,
  add column if not exists push_skip text;

update public.email_queue
   set pushed_at = now(), push_skip = 'before pop-ups'
 where pushed_at is null;

-- The kinds that are alerts: the list and the pop-ups read only these.
create or replace function private.is_alert(p_kind text)
returns boolean language sql immutable as $$
  select p_kind in ('grid_down', 'grid_back', 'batt_hot', 'bank_drift', 'string_dead',
                    'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back')
$$;

create index if not exists email_queue_alerts_idx on public.email_queue (user_id, created_at desc)
  where kind in ('grid_down', 'grid_back', 'batt_hot', 'bank_drift', 'string_dead',
                 'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back');
create index if not exists email_queue_push_idx on public.email_queue (id) where pushed_at is null;

-- ---------------------------------------------------------------------------
-- Devices and switches
-- ---------------------------------------------------------------------------
create table if not exists public.push_subs (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  platform    text not null default 'web' check (platform in ('web', 'expo')),
  endpoint    text not null unique,     -- web: the push service URL; expo: the push token
  p256dh      text,                     -- web only
  auth        text,                     -- web only
  created_at  timestamptz not null default now(),
  last_ok_at  timestamptz,
  check (platform <> 'web' or (p256dh is not null and auth is not null))
);
create index if not exists push_subs_user_idx on public.push_subs (user_id);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from public, anon, authenticated;
grant all on public.push_subs to service_role;

create table if not exists public.push_prefs (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  grid        boolean not null default true,
  battery     boolean not null default true,
  panels      boolean not null default true,
  readings    boolean not null default true,
  sunsynk     boolean not null default true,
  updated_at  timestamptz not null default now()
);
alter table public.push_prefs enable row level security;
drop policy if exists push_prefs_own on public.push_prefs;
create policy push_prefs_own on public.push_prefs
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
revoke all on public.push_prefs from anon, authenticated;
grant select (user_id, grid, battery, panels, readings, sunsynk) on public.push_prefs to authenticated;
grant insert (user_id, grid, battery, panels, readings, sunsynk) on public.push_prefs to authenticated;
grant update (user_id, grid, battery, panels, readings, sunsynk) on public.push_prefs to authenticated;
grant select, insert, update, delete on public.push_prefs to service_role;
drop trigger if exists push_prefs_touch on public.push_prefs;
create trigger push_prefs_touch before update on public.push_prefs
  for each row execute function public.email_prefs_touch();

-- This browser turned pop-ups on. An endpoint is one browser profile: a second
-- account signing in on it takes it over, so pop-ups follow whoever turned them on last.
create or replace function public.api_push_sub(p_endpoint text, p_p256dh text, p_auth text, p_platform text default 'web')
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  insert into public.push_subs (user_id, platform, endpoint, p256dh, auth)
  values (auth.uid(), p_platform, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, platform = excluded.platform, p256dh = excluded.p256dh,
        auth = excluded.auth, created_at = now(), last_ok_at = null;
end $$;

create or replace function public.api_push_unsub(p_endpoint text)
returns void language sql security definer set search_path = '' as $$
  delete from public.push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- ---------------------------------------------------------------------------
-- What an alert says
-- ---------------------------------------------------------------------------
-- {title, body, at, day, time, tab, switch} for one alert row. at: epoch of what
-- happened; a daily reminder of something that started days ago takes its own day.
-- tab: where a tap opens. day goes with it only for Grid and Solar, which show a day.
create or replace function private.alert_text(p_kind text, d jsonb, p_created timestamptz, p_tz text)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  ev bigint := coalesce((d->>'at')::bigint, (d->>'since')::bigint, extract(epoch from p_created)::bigint);
  hm text;
  lasted text;
  m int;
  inv text := nullif(d->>'inverter', '');
  title text; body text; tab text;
begin
  if ev < extract(epoch from p_created) - 43200 then ev := extract(epoch from p_created)::bigint; end if;
  hm := to_char(to_timestamp(coalesce((d->>'since')::bigint, ev)) at time zone p_tz, 'HH24:MI');
  if d ? 'at' and d ? 'since' then
    m := greatest(1, round(((d->>'at')::bigint - (d->>'since')::bigint) / 60.0)::int);
    lasted := case when m >= 60 then (m / 60) || ' h ' || (m % 60) || ' min' else m || ' min' end;
  end if;
  case p_kind
    when 'grid_down' then
      title := 'Grid down';
      body := 'Off since ' || hm || '.' || coalesce(' Battery ' || (d->>'chargePct') || '%, running the house.', '');
    when 'grid_back' then
      title := 'Grid back'; body := 'On again, after ' || lasted || ' without grid.';
    when 'batt_hot' then
      title := 'Battery hot'; body := (d->>'tempC') || ' °C. Batteries wear faster when they run hot.';
    when 'bank_drift' then
      title := 'Batteries charging unevenly';
      body := (select string_agg((b->>'name') || ' ' || (b->>'chargePct') || '%', ', ') from jsonb_array_elements(d->'banks') b)
              || '. Over an hour apart.';
    when 'string_dead' then
      title := 'Some panels stopped producing';
      body := (d->>'string') || ' on ' || (d->>'inverter') || '. The other panels are OK.';
    when 'logger_stale' then
      title := case when inv is null then 'No readings' else 'No readings from ' || inv end;
      body := 'No new reading for 15 minutes.' || case when inv is null then '' else ' Your other inverters are still reporting.' end;
    when 'logger_back' then
      title := case when inv is null then 'Readings back' else inv || ' back' end;
      body := 'Back after ' || lasted || '.';
    when 'sunsynk_down' then
      title := 'SunSynk is not answering'; body := 'Since ' || hm || ', so no readings can reach us.';
    when 'sunsynk_back' then
      title := 'SunSynk is back'; body := 'Readings are arriving again, after ' || lasted || '.';
    else return null;
  end case;
  tab := case when p_kind in ('grid_down', 'grid_back') then 'grid'
              when p_kind = 'string_dead' then 'solar'
              when p_kind in ('batt_hot', 'bank_drift') then 'inverters'
              else 'live' end;
  return jsonb_build_object(
    'title', title, 'body', body, 'at', ev, 'tab', tab, 'switch', private.email_switch(p_kind),
    'day', to_char(to_timestamp(ev) at time zone p_tz, 'YYYY-MM-DD'),
    'time', to_char(to_timestamp(ev) at time zone p_tz, 'HH24:MI'));
end $$;

-- ---------------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------------
create or replace function public.api_notifications()
returns jsonb language sql stable security definer set search_path = '' as $$
  with n as (
    select q.id, q.kind, q.plant_id, pu.plant_name, q.read_at, q.created_at,
           private.alert_text(q.kind, q.data, q.created_at, public.plant_tz(q.plant_id)) t
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid()
       and q.kind in ('grid_down', 'grid_back', 'batt_hot', 'bank_drift', 'string_dead',
                      'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back')
       and q.created_at > now() - interval '30 days'
     order by q.created_at desc, q.id desc
     limit 300)
  select jsonb_build_object(
    'pinned', '[]'::jsonb,
    'unread', (select count(*) from n where read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'plant', plant_id, 'plantName', plant_name, 'read', read_at is not null) || t
        order by created_at desc, id desc) from n), '[]'::jsonb));
$$;

create or replace function public.api_notifications_read(p_ids bigint[] default null)
returns void language sql security definer set search_path = '' as $$
  update public.email_queue
     set read_at = now()
   where user_id = auth.uid() and read_at is null
     and kind in ('grid_down', 'grid_back', 'batt_hot', 'bank_drift', 'string_dead',
                  'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back')
     and (p_ids is null or id = any (p_ids));
$$;

-- ---------------------------------------------------------------------------
-- Pop-ups
-- ---------------------------------------------------------------------------
create or replace function private.push_wanted(p_user uuid, p_switch text)
returns boolean language sql stable set search_path = '' as $$
  select coalesce((select case p_switch
                            when 'grid' then p.grid when 'battery' then p.battery when 'panels' then p.panels
                            when 'readings' then p.readings when 'sunsynk' then p.sunsynk end
                     from public.push_prefs p where p.user_id = p_user), true)
$$;

-- Up to p_limit alerts due a pop-up, each with its words and the user's web devices,
-- marked done at once: a pop-up is tried once, never twice. Rows nobody should get are
-- marked done with push_skip and not returned.
create or replace function public.push_claim(p_limit int default 200)
returns table (id bigint, user_id uuid, kind text, plant_id bigint, title text, body text,
               tab text, day text, subs jsonb)
language plpgsql security definer set search_path = public, private, pg_temp
as $$
begin
  create temp table if not exists _push (id bigint primary key, skip text) on commit drop;
  truncate _push;
  insert into _push (id, skip)
  select q.id,
         case
           when q.created_at < now() - interval '1 hour' then 'too old'
           when not exists (select 1 from public.plant_users pu where pu.user_id = q.user_id and pu.plant_id = q.plant_id)
             then 'plant removed'
           when not private.push_wanted(q.user_id, private.email_switch(q.kind)) then 'switched off'
           when not exists (select 1 from public.push_subs s where s.user_id = q.user_id and s.platform = 'web')
             then 'no device'
           when q.pair_key is not null and not exists (
                  select 1 from public.email_queue d
                   where d.user_id = q.user_id and d.key = q.pair_key and d.push_skip is null)
             then 'down had no pop-up'
         end
    from public.email_queue q
   where q.pushed_at is null
     and q.user_id is not null
     and private.is_alert(q.kind)
     -- a "back" waits until its "down" has been dealt with
     and not exists (select 1 from public.email_queue d
                      where q.pair_key is not null and d.user_id = q.user_id and d.key = q.pair_key and d.pushed_at is null)
   order by q.id
   limit p_limit
   for update of q skip locked;

  -- Not alerts (welcome, reports, billing): never a pop-up.
  update public.email_queue q set pushed_at = now(), push_skip = 'not an alert'
   where q.pushed_at is null and not private.is_alert(q.kind);
  update public.email_queue q set pushed_at = now(), push_skip = p.skip
    from _push p where p.id = q.id;

  return query
  select q.id, q.user_id, q.kind, q.plant_id,
         case when q.kind like 'sunsynk%' then t->>'title'
              else (t->>'title') || ' at ' || coalesce(pu.plant_name, 'your plant') end,
         t->>'body', t->>'tab',
         case when t->>'tab' in ('grid', 'solar') then t->>'day' end,
         (select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
            from public.push_subs s where s.user_id = q.user_id and s.platform = 'web')
    from _push p
    join public.email_queue q on q.id = p.id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
    cross join lateral (select private.alert_text(q.kind, q.data, q.created_at, public.plant_tz(q.plant_id)) t) x
   where p.skip is null
   order by q.id;
end $$;

create or replace function public.push_done(p_ok text[], p_gone text[])
returns void language sql security definer set search_path = '' as $$
  update public.push_subs set last_ok_at = now() where endpoint = any (p_ok);
  delete from public.push_subs where endpoint = any (p_gone);
$$;

revoke all on function private.is_alert(text) from public, anon, authenticated;
revoke all on function private.alert_text(text, jsonb, timestamptz, text) from public, anon, authenticated;
revoke all on function private.push_wanted(uuid, text) from public, anon, authenticated;
revoke all on function public.api_notifications() from public, anon;
revoke all on function public.api_notifications_read(bigint[]) from public, anon;
revoke all on function public.api_push_sub(text, text, text, text) from public, anon;
revoke all on function public.api_push_unsub(text) from public, anon;
revoke all on function public.push_claim(int) from public, anon, authenticated;
revoke all on function public.push_done(text[], text[]) from public, anon, authenticated;
grant execute on function public.api_notifications() to authenticated;
grant execute on function public.api_notifications_read(bigint[]) to authenticated;
grant execute on function public.api_push_sub(text, text, text, text) to authenticated;
grant execute on function public.api_push_unsub(text) to authenticated;
grant execute on function public.push_claim(int) to service_role;
grant execute on function public.push_done(text[], text[]) to service_role;
