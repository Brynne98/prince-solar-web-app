-- ============================================================================
-- 0164 — Disconnect and grid-off notices give when it happened, not when we noticed
-- (SOLAR-416).
--
-- 8 Nov, plant 538820: the login's last good poll was 13:53, the notice said 14:00 (the
-- poll that marked it dead). The grid went off at 14:51 inside a 13:53-14:55 gap; the
-- notice said 14:55 (the first reading after the gap). Now:
--
--   needs_relink   since = the login's last good poll (last_ok_at; account_mark leaves it
--                  alone). No last_ok_at: the time we noticed, as before.
--   grid_down      when the off run starts at the first reading after a gap (private.gaps,
--                  ended up to 5 min before the run start, as when the first minute back has no voltage), the start comes from the refilled per-inverter grid
--                  frequency: the first sample under 40 Hz after the last one at 40 Hz or
--                  over. If the refill has not landed yet, or shows no off sample, the
--                  row carries 'from' (the last on sample, else the gap's start) and the
--                  text says "Went off between 13:53 and 14:55". Grid back measures from
--                  the same start.
--
-- Rows already queued keep their data. email_plant_apply is the 0151 body, alert_text the
-- 0158 body, email_on_relink the 0158 body, with only the marked lines changed.
-- ============================================================================

-- When the grid went off, for an off run first seen at p_seen. {since} or {since, from}.
create or replace function private.grid_off_start(p_plant bigint, p_seen bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  with g as (
    -- a gap that ended up to 5 min before: the first minutes after it may have had no voltage
    select max(x.from_ts) from_ts from private.gaps x
     where x.plant_id = p_plant and x.to_ts <= p_seen and x.to_ts > p_seen - 300),
  h as (
    select i.ts, i.grid_fac_hz from public.inverter_history i, g
     where i.plant_id = p_plant and i.ts > g.from_ts and i.ts <= p_seen and i.grid_fac_hz is not null),
  last_on as (select max(ts) ts from h where grid_fac_hz >= 40),
  first_off as (select min(h.ts) ts from h, last_on where h.grid_fac_hz < 40 and h.ts > last_on.ts)
  select case
    when g.from_ts is null then jsonb_build_object('since', p_seen)
    when first_off.ts is not null then jsonb_build_object('since', first_off.ts)
    else jsonb_build_object('since', p_seen, 'from', coalesce(last_on.ts, g.from_ts)) end
    from g, last_on, first_off
$$;
revoke all on function private.grid_off_start(bigint, bigint) from public, anon, authenticated;

create or replace function private.email_plant_apply(p_plant bigint, p_ts bigint, f jsonb)
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  s private.plant_alert_state;
  present boolean := (f->>'present')::boolean;
  dev bigint := (f->>'dev')::bigint;
  temp numeric := (f->>'temp')::numeric;
  spread numeric := (f->>'spread')::numeric;
  k text;
  off jsonb;                                                                     -- 0164
begin
  insert into private.plant_alert_state (plant_id) values (p_plant) on conflict do nothing;
  select * into s from private.plant_alert_state where plant_id = p_plant for update;
  if s.stepped_ts is not null and p_ts <= s.stepped_ts then return; end if;

  -- Grid. Unknown minutes (no voltage reported) are skipped. Back needs 5 known minutes
  -- with grid once a Grid off went out (0151); a dip inside them is the same outage.
  if present is not null then
    if present is distinct from s.grid_run_on then
      s.grid_run_on := present; s.grid_run_n := 1; s.grid_run_start := p_ts;
    else
      s.grid_run_n := s.grid_run_n + 1;
    end if;
    if s.grid_on is distinct from s.grid_run_on
       and s.grid_run_n >= (case when not s.grid_run_on then 3 when s.grid_off_key is not null then 5 else 2 end) then
      if s.grid_on is null then
        null;                                       -- first state seen: taken silently
      elsif not s.grid_run_on then
        k := 'grid_down:' || p_plant || ':' || s.grid_run_start;
        off := private.grid_off_start(p_plant, s.grid_run_start);                    -- 0164
        perform private.email_enqueue_plant(p_plant, 'grid_down', k, off || jsonb_build_object(   -- 0164
          'chargePct', (select round(a.soc)::int from public.agg_minute a
                         where a.plant_id = p_plant and a.ts between p_ts - 600 and p_ts and a.soc is not null
                         order by a.ts desc limit 1)));
        s.grid_off_key := k;
        s.grid_run_start := (off->>'since')::bigint;                                 -- 0164: grid back counts from here
      elsif s.grid_off_key is not null then
        perform private.email_enqueue_plant(p_plant, 'grid_back', 'grid_back:' || p_plant || ':' || s.grid_since,
          jsonb_build_object('since', s.grid_since, 'at', s.grid_run_start), s.grid_off_key);
        s.grid_off_key := null;
      end if;
      s.grid_on := s.grid_run_on; s.grid_since := s.grid_run_start;
    end if;
  end if;

  -- Readings: SunSynk's own clock, the newest device_time on the plant this minute.
  -- While stale, back once readings have come for 15 min with no gap over 10 min (0151).
  if dev is not null and dev > coalesce(s.last_dev, 0) then
    if s.stale then
      if s.stale_clear_at is null or dev - s.last_dev > 600 then s.stale_clear_at := dev; end if;
      if extract(epoch from now()) - dev <= 900 and dev - s.stale_clear_at >= 900 then
        if s.stale_key is not null then
          perform private.email_enqueue_plant(p_plant, 'logger_back', 'logger_back:' || substr(s.stale_key, 14),
            jsonb_build_object('since', split_part(s.stale_key, ':', 3)::bigint, 'at', s.stale_clear_at), s.stale_key);
        end if;
        s.stale := false; s.stale_key := null; s.stale_clear_at := null;
      end if;
    end if;
    s.last_dev := dev;
  end if;

  -- Battery temperature: the hottest inverter this minute, over 45 C (unrounded, as the
  -- app judges it) for 3 minutes in a row. A minute with no temperature, or a gap of
  -- more than 2 minutes, starts the count again. Ends after 15 min at 43 C or below.
  if (f->>'has_batt')::boolean and temp is not null then
    s.hot_run_n := case when temp <= 45 then 0
                        when p_ts - coalesce(s.hot_at, 0) <= 120 then s.hot_run_n + 1 else 1 end;
    s.hot_temp := round(temp); s.hot_at := p_ts;
    if not s.hot and s.hot_run_n >= 3 then
      s.hot := true; s.hot_since := p_ts - 120; s.hot_n := 1; s.hot_sent_at := now(); s.hot_clear_at := null;
      perform private.email_enqueue_plant(p_plant, 'batt_hot', 'batt_hot:' || p_plant || ':' || s.hot_since || ':1',
        jsonb_build_object('at', p_ts, 'tempC', round(temp)));
    elsif s.hot and temp <= 43 then
      s.hot_clear_at := coalesce(s.hot_clear_at, p_ts);
      if p_ts - s.hot_clear_at >= 900 then
        perform private.email_enqueue_plant(p_plant, 'batt_hot_back', 'batt_hot_back:' || p_plant || ':' || s.hot_since,
          jsonb_build_object('since', s.hot_since, 'at', s.hot_clear_at, 'tempC', round(temp)),
          'batt_hot:' || p_plant || ':' || s.hot_since || ':1');
        s.hot := false; s.hot_clear_at := null;
      end if;
    elsif s.hot then
      s.hot_clear_at := null;
    end if;
  end if;

  -- Charge spread between inverters' own batteries. Ends after 15 min under 8 points.
  if (f->>'has_batt')::boolean and not (f->>'shared')::boolean then
    if spread is not null then
      if spread >= 10 then
        s.drift_run_start := coalesce(s.drift_run_start, p_ts);
        s.drift_clear_at := null;
        s.drift_banks := (select jsonb_agg(jsonb_build_object('name', coalesce(nullif(m.alias, ''), 'Inverter ' || r.sn),
                                                              'chargePct', round(r.batt_soc)::int) order by m.ord nulls last, r.sn)
                            from public.readings r left join private.meta m on m.sn = r.sn
                           where r.plant_id = p_plant and r.ts = p_ts and r.batt_soc between 1 and 100);
        if not s.drift and p_ts - s.drift_run_start >= 3600 then
          s.drift := true; s.drift_since := s.drift_run_start; s.drift_n := 1; s.drift_sent_at := now();
          perform private.email_enqueue_plant(p_plant, 'bank_drift', 'bank_drift:' || p_plant || ':' || s.drift_since || ':1',
            jsonb_build_object('since', s.drift_since, 'banks', s.drift_banks));
        end if;
      else
        s.drift_run_start := null;
        if s.drift and spread < 8 then
          s.drift_clear_at := coalesce(s.drift_clear_at, p_ts);
          if p_ts - s.drift_clear_at >= 900 then
            perform private.email_enqueue_plant(p_plant, 'bank_drift_back', 'bank_drift_back:' || p_plant || ':' || s.drift_since,
              jsonb_build_object('since', s.drift_since, 'at', s.drift_clear_at,
                'banks', (select jsonb_agg(jsonb_build_object('name', coalesce(nullif(m.alias, ''), 'Inverter ' || r.sn),
                                                              'chargePct', round(r.batt_soc)::int) order by m.ord nulls last, r.sn)
                            from public.readings r left join private.meta m on m.sn = r.sn
                           where r.plant_id = p_plant and r.ts = p_ts and r.batt_soc between 1 and 100)),
              'bank_drift:' || p_plant || ':' || s.drift_since || ':1');
            s.drift := false; s.drift_clear_at := null;
          end if;
        elsif s.drift then
          s.drift_clear_at := null;
        end if;
      end if;
    end if;
  elsif s.drift or s.drift_run_start is not null then
    s.drift := false; s.drift_run_start := null; s.drift_clear_at := null;
  end if;

  s.stepped_ts := p_ts;
  update private.plant_alert_state set
    grid_on = s.grid_on, grid_since = s.grid_since, grid_off_key = s.grid_off_key,
    grid_run_on = s.grid_run_on, grid_run_n = s.grid_run_n, grid_run_start = s.grid_run_start,
    last_dev = s.last_dev, stale = s.stale, stale_key = s.stale_key, stale_clear_at = s.stale_clear_at,
    hot = s.hot, hot_since = s.hot_since, hot_temp = s.hot_temp, hot_at = s.hot_at, hot_sent_at = s.hot_sent_at, hot_n = s.hot_n,
    hot_run_n = s.hot_run_n, hot_clear_at = s.hot_clear_at,
    drift = s.drift, drift_run_start = s.drift_run_start, drift_since = s.drift_since, drift_banks = s.drift_banks,
    drift_sent_at = s.drift_sent_at, drift_n = s.drift_n, drift_clear_at = s.drift_clear_at, stepped_ts = s.stepped_ts
  where plant_id = p_plant;
end $$;

create or replace function private.email_on_relink()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  now_s bigint := extract(epoch from now())::bigint;
  since_s bigint := coalesce(extract(epoch from old.last_ok_at)::bigint, extract(epoch from now())::bigint);  -- 0164: last good poll
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
                   then 'Went off between ' || to_char(to_timestamp((d->>'from')::bigint) at time zone p_tz, 'HH24:MI')
                        || ' and ' || hm || '.'
                   else 'Off since ' || hm || '.' end
              || coalesce(' Battery ' || (d->>'chargePct') || '%.', '');
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
      title := 'Reconnect needed'; body := 'SunSynk login stopped at ' || hm || '.';
    when 'relinked' then
      title := 'Reconnected'; body := 'Back after ' || lasted || '.';
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

revoke all on function private.email_plant_apply(bigint, bigint, jsonb) from public, anon, authenticated;
