-- ============================================================================
-- 0229 — Alert pop-ups read right on a phone lock screen (SOLAR-485).
--
-- Seen 11 Nov on an iPhone: "Grid down at Grid-tied" / "Off since 01:28." The plant name
-- glued to the title read as a place, long titles were cut off with the name, and "back"
-- alerts said "back" twice. Now:
--
--   one plant      title = what happened, body = the numbers. No plant name.
--   2+ plants      title = the plant name ("SunSynk" for SunSynk and login alerts, which
--                  are not one plant), body = what happened and the numbers in one line:
--                  "Grid down since 01:28. Battery 64%."
--
-- Words (alert_text, also the Notifications page): a back alert says how long it lasted,
-- never "back" again; battery drift is "charge uneven" (true while discharging too); a dead
-- string is "Some panels"; a dead login says what to do. Titles are 29 characters or less.
--
-- alert_text is the 0164 body, push_claim the 0124 body, with only the text changed.
-- ============================================================================

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
      title := 'Sign in to SunSynk again'; body := 'Login stopped working at ' || hm || '.';
    when 'relinked' then
      title := 'SunSynk reconnected'; body := 'Signed out for ' || lasted || '.';
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

-- The pop-up's title and body from alert_text, by how many plants the user has.
create or replace function private.push_text(p_kind text, t jsonb, p_plant_name text, p_plants int)
returns table (title text, body text) language sql immutable set search_path = '' as $$
  select case when p_plants < 2 then t->>'title'
              when p_kind like 'sunsynk%' or p_kind in ('needs_relink', 'relinked') then 'SunSynk'
              else coalesce(p_plant_name, 'Your plant') end,
         case when p_plants < 2 then t->>'body'
              -- "Grid down" + "Since 01:28." reads as one sentence
              when t->>'body' ~ '^(Since|Between) ' then (t->>'title') || ' ' || lower(left(t->>'body', 1)) || substr(t->>'body', 2)
              else (t->>'title') || '. ' || (t->>'body') end
$$;

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

revoke all on function private.push_text(text, jsonb, text, int) from public, anon, authenticated;
