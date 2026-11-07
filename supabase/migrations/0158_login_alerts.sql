-- ============================================================================
-- 0158 — A dead SunSynk login shows in the app, per plant (SOLAR-380).
--
-- On 5 Nov 495944's login died. Both owners got the email (needs_relink), but the
-- Notifications page and the pop-ups take alert kinds only (is_alert), so the app said
-- nothing. The email named no plant either. Now:
--
--   needs_relink   one row per user per plant on the login, when it dies. Each names its
--                  plant (the row's plant) and the login (data.login). Only the first
--                  plant's row emails; it lists every plant on the login (data.plants).
--                  The others go in as skipped, so one login is one email.
--   relinked       new: the login works again (status needs_relink -> active, account_upsert
--                  and its copies). Same shape, paired to its needs_relink (pair_key), so the
--                  page shows "17:40 to 19:45, 2h 5m" and the pop-up replaces the first.
--   No switch      email_switch stays null for both: always on, email and pop-up. The
--                  page's SunSynk filter lists them (api_alerts below).
--   Tap            the pop-up opens Account on the logins (tab account, notify adds
--                  section=logins).
--
-- Bodies: alert_text is 0154's, api_alerts 0152's, email_on_relink 0102's, with only the
-- parts above changed. Old needs_relink rows (data {account} only) read with their
-- created_at as the time and no login name.
-- ============================================================================

create or replace function private.is_alert(p_kind text)
returns boolean language sql immutable as $$
  select p_kind in ('grid_down', 'grid_back', 'batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back',
                    'string_dead', 'string_back', 'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back',
                    'needs_relink', 'relinked')
$$;

drop index if exists public.email_queue_alerts_idx;
create index email_queue_alerts_idx on public.email_queue (user_id, created_at desc)
  where kind in ('grid_down', 'grid_back', 'batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back',
                 'string_dead', 'string_back', 'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back',
                 'needs_relink', 'relinked');

create or replace function private.alert_back_kind(p_kind text)
returns text language sql immutable as $$
  select case p_kind
    when 'grid_down' then 'grid_back' when 'logger_stale' then 'logger_back'
    when 'sunsynk_down' then 'sunsynk_back' when 'batt_hot' then 'batt_hot_back'
    when 'bank_drift' then 'bank_drift_back' when 'string_dead' then 'string_back'
    when 'needs_relink' then 'relinked' end
$$;

-- the page's kind filter: the email switch, and SunSynk for a login (which has no switch)
create or replace function private.alert_group(p_kind text)
returns text language sql immutable as $$
  select coalesce(private.email_switch(p_kind), case when p_kind in ('needs_relink', 'relinked') then 'sunsynk' end)
$$;

-- ---------------------------------------------------------------------------
-- Queueing
-- ---------------------------------------------------------------------------
create or replace function private.email_on_relink()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  now_s bigint := extract(epoch from now())::bigint;
  names jsonb;
  r record;
  n int := 0;
begin
  -- every plant this user has on the login, oldest link first; the email lists them all
  select coalesce(jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at), '[]'::jsonb)
    into names
    from public.plant_users pu where pu.account_id = new.id and pu.user_id = new.user_id;

  if new.status = 'needs_relink' and old.status is distinct from 'needs_relink' then
    for r in select pu.plant_id from public.plant_users pu
              where pu.account_id = new.id and pu.user_id = new.user_id order by pu.linked_at loop
      n := n + 1;
      insert into public.email_queue (user_id, plant_id, kind, key, data, priority, status, last_error)
      values (new.user_id, r.plant_id, 'needs_relink', 'needs_relink:' || new.id || ':' || r.plant_id || ':' || now_s,
              jsonb_build_object('account', new.id, 'login', new.sunsynk_username, 'since', now_s, 'plants', names), 0,
              case when n = 1 then 'queued' else 'skipped' end, case when n > 1 then 'one email per login' end)
      on conflict do nothing;
    end loop;
    -- a login with no plant still gets its email, as before
    if n = 0 then
      insert into public.email_queue (user_id, kind, key, data, priority)
      values (new.user_id, 'needs_relink', 'needs_relink:' || new.id || ':' || now_s,
              jsonb_build_object('account', new.id, 'login', new.sunsynk_username, 'since', now_s, 'plants', names), 0)
      on conflict do nothing;
    end if;

  elsif old.status = 'needs_relink' and new.status = 'active' then
    -- each plant's latest dead-login row with no "back" yet
    for r in
      select d.plant_id, d.key, d.status, coalesce((d.data->>'since')::bigint, extract(epoch from d.created_at)::bigint) since
        from public.plant_users pu
        cross join lateral (select q.* from public.email_queue q
                             where q.user_id = new.user_id and q.plant_id = pu.plant_id and q.kind = 'needs_relink'
                               and q.data->>'account' = new.id::text
                             order by q.id desc limit 1) d
       where pu.account_id = new.id and pu.user_id = new.user_id
         and not exists (select 1 from public.email_queue b where b.user_id = new.user_id and b.pair_key = d.key)
       order by pu.linked_at
    loop
      -- the email goes on the plant whose "down" emailed, so email_claim pairs them
      insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority, status, last_error)
      values (new.user_id, r.plant_id, 'relinked', 'relinked:' || new.id || ':' || r.plant_id || ':' || now_s, r.key,
              jsonb_build_object('account', new.id, 'login', new.sunsynk_username, 'since', r.since, 'at', now_s, 'plants', names), 0,
              case when r.status <> 'skipped' then 'queued' else 'skipped' end,
              case when r.status = 'skipped' then 'one email per login' end)
      on conflict do nothing;
    end loop;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- Bell, page and pop-up text
-- ---------------------------------------------------------------------------
create or replace function private.alert_text(p_kind text, d jsonb, p_created timestamptz, p_tz text)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  ev bigint := coalesce((d->>'at')::bigint, (d->>'since')::bigint, extract(epoch from p_created)::bigint);
  hm text;
  lasted text;
  m int;
  inv text := nullif(d->>'inverter', '');
  login text := coalesce('Login ' || nullif(d->>'login', ''), 'Login');
  title text; body text; tab text;
begin
  if ev < extract(epoch from p_created) - 43200 then ev := extract(epoch from p_created)::bigint; end if;
  hm := to_char(to_timestamp(coalesce((d->>'since')::bigint, ev)) at time zone p_tz, 'HH24:MI');
  if d ? 'at' and d ? 'since' then
    m := greatest(1, round(((d->>'at')::bigint - (d->>'since')::bigint) / 60.0)::int);
    -- the app's and emails' format: 45 min, 1h 33m, 2h
    lasted := case when m < 60 then m || ' min' when m % 60 = 0 then (m / 60) || 'h'
                   else (m / 60) || 'h ' || (m % 60) || 'm' end;
  end if;
  case p_kind
    when 'grid_down' then
      title := 'Grid down';
      body := 'Off since ' || hm || '.' || coalesce(' Battery ' || (d->>'chargePct') || '%.', '');
    when 'grid_back' then
      title := 'Grid back'; body := 'Back after ' || lasted || '.';
    when 'batt_hot' then
      title := 'Battery hot'; body := (d->>'tempC') || ' °C at ' || hm || '.';
    when 'batt_hot_back' then
      title := 'Battery cooled'; body := (d->>'tempC') || ' °C. Hot for ' || lasted || '.';
    when 'bank_drift' then
      title := 'Batteries charging unevenly';
      body := (select string_agg((b->>'name') || ' ' || (b->>'chargePct') || '%', ', ') from jsonb_array_elements(d->'banks') b)
              || '.';
    when 'bank_drift_back' then
      title := 'Batteries charging evenly';
      body := (select string_agg((b->>'name') || ' ' || (b->>'chargePct') || '%', ', ') from jsonb_array_elements(d->'banks') b)
              || '. Apart for ' || lasted || '.';
    when 'string_dead' then
      title := 'Panels stopped producing';
      body := (d->>'inverter') || ', ' || lower(d->>'string') || ', since ' || hm || '.';
    when 'string_back' then
      title := 'Panels producing again';
      body := (d->>'inverter') || ', ' || lower(d->>'string') || '. Stopped for ' || lasted || '.';
    when 'logger_stale' then
      title := case when inv is null then 'No readings' else 'No readings from ' || inv end;
      body := 'Last reading ' || hm || '.';
    when 'logger_back' then
      title := case when inv is null then 'Readings back' else inv || ' back' end;
      body := 'Back after ' || lasted || '.';
    when 'sunsynk_down' then
      title := 'SunSynk is down'; body := 'Since ' || hm || '.';
    when 'sunsynk_back' then
      title := 'SunSynk is back'; body := 'Back after ' || lasted || '.';
    when 'needs_relink' then
      title := 'Reconnect needed'; body := login || ' stopped at ' || hm || '.';
    when 'relinked' then
      title := 'Reconnected'; body := login || ' back after ' || lasted || '.';
    else return null;
  end case;
  tab := case when p_kind in ('grid_down', 'grid_back') then 'grid'
              when p_kind in ('string_dead', 'string_back') then 'inverters'
              when p_kind in ('batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back') then 'inverters'
              when p_kind in ('needs_relink', 'relinked') then 'account'
              else 'live' end;
  return jsonb_build_object(
    'title', title, 'body', body, 'at', ev, 'tab', tab, 'switch', private.alert_group(p_kind),
    'day', to_char(to_timestamp(ev) at time zone p_tz, 'YYYY-MM-DD'),
    'time', to_char(to_timestamp(ev) at time zone p_tz, 'HH24:MI'));
end $$;

-- ---------------------------------------------------------------------------
-- The page: as 0152, filtered by alert_group so SunSynk lists logins too
-- ---------------------------------------------------------------------------
create or replace function public.api_alerts(p_from timestamptz default null, p_switch text default null,
                                             p_unread boolean default false, p_before bigint default null,
                                             p_before_ts timestamptz default null, p_limit int default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  with a as (
    -- every alert the user can still see: plants still linked
    select q.id, q.kind, q.key, q.pair_key, q.plant_id, pu.plant_name, q.read_at, q.created_at, q.data
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid() and private.is_alert(q.kind)),
  e as (
    -- one row per alert: each start, and a "back" whose start is gone
    select s.*, b.id b_id, b.read_at b_read, b.created_at b_created, b.data b_data, b.kind b_kind
      from a s
      left join lateral (select x.* from public.email_queue x where x.user_id = auth.uid() and x.pair_key = s.key
                          order by x.id limit 1) b on true
     where (s.pair_key is null or not exists (select 1 from public.email_queue d where d.user_id = auth.uid() and d.key = s.pair_key))
       and (p_from is null or s.created_at >= p_from)
       and (p_switch is null or private.alert_group(s.kind) = p_switch)
       and (p_before is null or (s.created_at, s.id) < (p_before_ts, p_before))
       and (not p_unread or s.read_at is null or (b.id is not null and b.read_at is null))
     order by s.created_at desc, s.id desc
     limit greatest(1, least(p_limit, 200)) + 1),
  shown as (select * from e order by created_at desc, id desc limit greatest(1, least(p_limit, 200))),
  -- when each "back" kind was first sent, by anyone; Reconnected exists from 0158 on
  firsts as (select f.kind, min(f.at) at from (
               select q.kind, q.created_at at from public.email_queue q
                where q.kind in (select private.alert_back_kind(k.kind) from shown k)
               union all select 'relinked', timestamptz '2026-11-07 12:00+02') f
              group by f.kind)
  select jsonb_build_object(
    'more', (select count(*) from e) > greatest(1, least(p_limit, 200)),
    'unread', (select count(*) from a where read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'ts', s.created_at, 'kind', s.kind, 'plant', s.plant_id, 'plantName', s.plant_name,
        'read', s.read_at is not null and (s.b_id is null or s.b_read is not null),
        'ids', to_jsonb(array_remove(array[s.id, s.b_id], null)),
        'endAt', (bt->>'at')::bigint,
        'endDay', bt->>'day', 'endTime', bt->>'time',
        'open', s.b_id is null and coalesce(private.is_alert(private.alert_back_kind(s.kind)), false)
                and coalesce(s.created_at >= (select f.at from firsts f where f.kind = private.alert_back_kind(s.kind)), false)
                and not exists (select 1 from public.email_queue l where l.user_id = auth.uid() and l.plant_id = s.plant_id
                                  and l.kind = s.kind and l.created_at > s.created_at))
        || t
        order by s.created_at desc, s.id desc) from shown s
        cross join lateral (select private.alert_text(s.kind, s.data, s.created_at, public.plant_tz(s.plant_id)) t) x
        left join lateral (select private.alert_text(s.b_kind, s.b_data, s.b_created, public.plant_tz(s.plant_id)) bt) y on true),
      '[]'::jsonb));
$$;

revoke all on function private.alert_group(text) from public, anon, authenticated;

-- Dead logins from before 0158 were emailed long ago: on the page as history, not as
-- new unread notifications.
update public.email_queue set read_at = now() where kind = 'needs_relink' and read_at is null;
