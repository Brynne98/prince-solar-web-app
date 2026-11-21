-- ============================================================================
-- 0232 — One login stopping is one alert, naming every plant (SOLAR-614).
--
-- email_on_relink writes a needs_relink (and later a relinked) row per plant on the
-- login; only the first emails, the rest are 'skipped' with 'one email per login'.
-- The bell and Notifications showed every row, and push_claim popped each one up.
-- Now:
--   api_alerts      rows of one login's stop (kind, account, since) show once, on the
--                   emailed row when the user can read its plant; ids holds every row,
--                   so reading it reads them all. Old rows are hidden, not deleted.
--   alert_text      with 2+ plants on the login, the body names them:
--                   "Login for Farm and Farm strings stopped working at 17:48."
--   push_claim      the skipped copies get push_skip 'one per login', so a stop and its
--                   return are one pop-up each, also for a login down at deploy.
--   email_on_relink the emailed row goes on an unpaused plant first.
--
-- Bodies: email_on_relink 0177, alert_text and push_claim 0229, api_alerts 0204, with
-- only the lines marked 0232 changed. No rows are written here.
-- ============================================================================

-- "Farm", "Farm and Farm strings", "A, B and C"
create or replace function private.name_list(p_names jsonb)
returns text language sql immutable set search_path = '' as $$
  select case when jsonb_array_length(p_names) <= 1 then p_names->>0
              else (select string_agg(n, ', ' order by o) from jsonb_array_elements_text(p_names) with ordinality e(n, o)
                     where o < jsonb_array_length(p_names))
                   || ' and ' || (p_names->>-1) end
$$;
revoke all on function private.name_list(jsonb) from public, anon, authenticated;

create or replace function private.email_on_relink()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  now_s bigint := extract(epoch from now())::bigint;
  since_s bigint := coalesce(extract(epoch from old.last_ok_at)::bigint, extract(epoch from now())::bigint);  -- 0164: last good poll
  names jsonb;
  r record;
  n int := 0;
begin
  -- 0177: the share login. Each owner of a claimed shared plant gets one email when it
  -- stops and one when it is back. No sign-in wording: owners can't act on it. The
  -- company user, who owns the login, gets nothing.
  if new.kind = 'share' then
    if new.status = 'needs_relink' and old.status is distinct from 'needs_relink' then
      insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
      select o.user_id, o.plant_id, 'share_down', 'share_down:' || new.id || ':' || o.user_id || ':' || now_s,
             jsonb_build_object('account', new.id, 'since', since_s, 'plants', o.names), 0
        from (select pu.user_id, (array_agg(pu.plant_id order by pu.linked_at))[1] plant_id,
                     jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at) names
                from public.plant_users pu
               where pu.account_id = new.id and pu.via_share and pu.share_gone_at is null and not pu.paused
               group by pu.user_id) o
      on conflict do nothing;
    elsif old.status = 'needs_relink' and new.status = 'active' then
      -- each owner's latest "stopped" with no "back" yet; paired so email_claim drops a
      -- "back" whose "stopped" never went
      insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
      select d.user_id, d.plant_id, 'share_back', 'share_back:' || new.id || ':' || d.user_id || ':' || now_s, d.key,
             jsonb_build_object('account', new.id, 'since', coalesce((d.data->>'since')::bigint, extract(epoch from d.created_at)::bigint),
                                'at', now_s, 'plants', d.data->'plants'), 0
        from (select distinct on (q.user_id) q.* from public.email_queue q
               where q.kind = 'share_down' and q.data->>'account' = new.id::text
               order by q.user_id, q.id desc) d
       where not exists (select 1 from public.email_queue b where b.user_id = d.user_id and b.pair_key = d.key)
      on conflict do nothing;
    end if;
    return null;
  end if;

  -- every plant this user has on the login, oldest link first; the email lists them all
  select coalesce(jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at), '[]'::jsonb)
    into names
    from public.plant_users pu where pu.account_id = new.id and pu.user_id = new.user_id;

  if new.status = 'needs_relink' and old.status is distinct from 'needs_relink' then
    for r in select pu.plant_id from public.plant_users pu
              where pu.account_id = new.id and pu.user_id = new.user_id order by pu.paused, pu.linked_at loop  -- 0232
      n := n + 1;
      insert into public.email_queue (user_id, plant_id, kind, key, data, priority, status, last_error)
      values (new.user_id, r.plant_id, 'needs_relink', 'needs_relink:' || new.id || ':' || r.plant_id || ':' || now_s,
              jsonb_build_object('account', new.id, 'since', since_s, 'plants', names), 0,
              case when n = 1 then 'queued' else 'skipped' end, case when n > 1 then 'one email per login' end)
      on conflict do nothing;
    end loop;
    -- a login with no plant still gets its email, as before
    if n = 0 then
      insert into public.email_queue (user_id, kind, key, data, priority)
      values (new.user_id, 'needs_relink', 'needs_relink:' || new.id || ':' || now_s,
              jsonb_build_object('account', new.id, 'since', since_s, 'plants', names), 0)
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
              jsonb_build_object('account', new.id, 'since', r.since, 'at', now_s, 'plants', names), 0,
              case when r.status <> 'skipped' then 'queued' else 'skipped' end,
              case when r.status = 'skipped' then 'one email per login' end)
      on conflict do nothing;
    end loop;
  end if;
  return null;
end $$;

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
    -- the app's and emails' format: 45 min, 1h 33m, 2h
    lasted := case when m < 60 then m || ' min' when m % 60 = 0 then (m / 60) || 'h'
                   else (m / 60) || 'h ' || (m % 60) || 'm' end;
  end if;
  case p_kind
    when 'grid_down' then
      title := 'Grid down';
      body := case when d ? 'from'                                               -- 0164: went off inside a gap
                   then 'Between ' || to_char(to_timestamp((d->>'from')::bigint) at time zone p_tz, 'HH24:MI')
                        || ' and ' || hm || '.'
                   else 'Since ' || hm || '.' end
              || coalesce(' Battery ' || (d->>'chargePct') || '%.', '');
    when 'grid_back' then
      title := 'Grid back'; body := 'Down for ' || lasted || '.';
    when 'batt_hot' then
      title := 'Battery hot'; body := (d->>'tempC') || ' °C since ' || hm || '.';
    when 'batt_hot_back' then
      title := 'Battery cooled'; body := (d->>'tempC') || ' °C. Hot for ' || lasted || '.';
    when 'bank_drift' then
      title := 'Battery charge uneven';
      body := (select string_agg((b->>'name') || ' ' || (b->>'chargePct') || '%', ', ') from jsonb_array_elements(d->'banks') b)
              || '.';
    when 'bank_drift_back' then
      title := 'Battery charge even again';
      body := (select string_agg((b->>'name') || ' ' || (b->>'chargePct') || '%', ', ') from jsonb_array_elements(d->'banks') b)
              || '. Uneven for ' || lasted || '.';
    when 'string_dead' then
      title := 'Some panels stopped producing';
      body := (d->>'inverter') || ', ' || lower(d->>'string') || ', since ' || hm || '.';
    when 'string_back' then
      title := 'Panels producing again';
      body := (d->>'inverter') || ', ' || lower(d->>'string') || '. Stopped for ' || lasted || '.';
    when 'logger_stale' then
      title := case when inv is null then 'No readings' else 'No readings from ' || inv end;
      body := 'Since ' || hm || '.';
    when 'logger_back' then
      title := case when inv is null then 'Readings back' else inv || ' readings back' end;
      body := 'Missing for ' || lasted || '.';
    when 'sunsynk_down' then
      title := 'SunSynk is down'; body := 'No new readings since ' || hm || '.';
    when 'sunsynk_back' then
      title := 'SunSynk is back'; body := 'Down for ' || lasted || '.';
    when 'needs_relink' then
      title := 'Sign in to SunSynk again';
      body := case when jsonb_array_length(coalesce(d->'plants', '[]')) >= 2                -- 0232
                   then 'Login for ' || private.name_list(d->'plants') || ' stopped working at ' || hm || '.'
                   else 'Login stopped working at ' || hm || '.' end;
    when 'relinked' then
      title := 'SunSynk reconnected';
      body := case when jsonb_array_length(coalesce(d->'plants', '[]')) >= 2                -- 0232
                   then private.name_list(d->'plants') || ' were signed out for ' || lasted || '.'
                   else 'Signed out for ' || lasted || '.' end;
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
           when q.status = 'skipped' and q.last_error = 'one email per login' then 'one per login'   -- 0232
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
         pt.title,                                                                -- 0229
         pt.body,                                                                 -- 0229
         t->>'tab',
         case when t->>'tab' in ('grid', 'solar') then t->>'day' end,
         (select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
            from public.push_subs s where s.user_id = q.user_id and s.platform = 'web')
    from _push p
    join public.email_queue q on q.id = p.id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
    cross join lateral (select private.alert_text(q.kind, q.data, q.created_at, public.plant_tz(q.plant_id)) t) x
    cross join lateral private.push_text(q.kind, x.t, pu.plant_name,                -- 0229
      (select count(*)::int from public.plant_users n where n.user_id = q.user_id)) pt
   where p.skip is null
   order by q.id;
end $$;

-- 0204's api_alerts, with one row per login stop (0232).
CREATE OR REPLACE FUNCTION public.api_alerts(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_switch text DEFAULT NULL::text, p_unread boolean DEFAULT false, p_before bigint DEFAULT NULL::bigint, p_before_ts timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with raw as (
    -- every alert the user can still see: plants still linked, and readable (0204)
    select q.id, q.kind, q.key, q.plant_id, pu.plant_name, q.read_at, q.created_at, q.data, q.status,
           -- one login stopping (or coming back) writes a row per plant: one group (0232)
           -- (rows from before 0158 have no since: each stays its own)
           coalesce(case when q.kind in ('needs_relink', 'relinked') and q.data ? 'since'
                         then q.kind || ':' || coalesce(q.data->>'account', '') || ':' || (q.data->>'since') end,
                    q.id::text) grp
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid() and private.is_alert(q.kind)
       and q.plant_id in (select public.my_plant_ids())),
  a as (
    -- each group shows once, on its emailed row when readable; read when every row is
    select z.* from (
      select r.*, jsonb_agg(r.id) over w ids, bool_and(r.read_at is not null) over w is_read,
             row_number() over (partition by r.grp order by r.status = 'skipped', r.id) rn
        from raw r window w as (partition by r.grp)) z
     where z.rn = 1),
  e as (
    select s.* from a s
     where (p_from is null or s.created_at >= p_from)
       and (p_switch is null or private.alert_group(s.kind) = p_switch)
       and (p_before is null or (s.created_at, s.id) < (p_before_ts, p_before))
       and (not p_unread or not s.is_read)
     order by s.created_at desc, s.id desc
     limit greatest(1, least(p_limit, 200)) + 1),
  shown as (select * from e order by created_at desc, id desc limit greatest(1, least(p_limit, 200))),
  -- when each "back" kind was first sent, by anyone; Reconnected exists from 0158 on
  firsts as (select f.kind, min(f.at) at from (
               select q.kind, q.created_at at from public.email_queue q
                where q.kind in (select private.alert_back_kind(k.kind) from shown k)
               union all select 'relinked', timestamptz '2026-11-07 00:00+02') f
              group by f.kind)
  select jsonb_build_object(
    'more', (select count(*) from e) > greatest(1, least(p_limit, 200)),
    'unread', (select count(*) from a where not is_read),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'ts', s.created_at, 'kind', s.kind, 'plant', s.plant_id, 'plantName', s.plant_name,
        'read', s.is_read,
        'ids', s.ids,
        'open', coalesce(private.is_alert(private.alert_back_kind(s.kind)), false)
                and not exists (select 1 from public.email_queue b where b.user_id = auth.uid() and b.pair_key = s.key)
                and coalesce(s.created_at >= (select f.at from firsts f where f.kind = private.alert_back_kind(s.kind)), false)
                and not exists (select 1 from public.email_queue l where l.user_id = auth.uid() and l.plant_id = s.plant_id
                                  and l.kind = s.kind and l.created_at > s.created_at))
        || t
        order by s.created_at desc, s.id desc) from shown s
        cross join lateral (select private.alert_text(s.kind, private.grid_notice_data(s.plant_id, s.kind, s.data),   -- 0167
                                                      s.created_at, public.plant_tz(s.plant_id)) t) x),
      '[]'::jsonb));
$function$;
