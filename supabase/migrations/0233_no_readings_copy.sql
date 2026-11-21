-- ============================================================================
-- 0233 — No readings / Readings back: bell and pop-up words (SOLAR-560).
--
-- The one-inverter alerts named the inverter by its bare serial ("No readings from
-- 2504193036", "2504193036 readings back"); the email says "Inverter 2504193036".
-- A name that is only digits now gets "Inverter " in front, as the email does.
-- Readings back said "Missing for 1h 6m."; the email says "No readings for".
--   logger_stale  "No readings" / "No readings from Inverter 2504193036", "Since 22:03."
--   logger_back   "Readings back" / "Readings back from Inverter 2504193036",
--                 "No readings for 1h 51m."
--
-- Body: alert_text 0232, with only the lines marked 0233 changed. No rows are written.
-- ============================================================================

create or replace function private.alert_text(p_kind text, d jsonb, p_created timestamptz, p_tz text)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  ev bigint := coalesce((d->>'at')::bigint, (d->>'since')::bigint, extract(epoch from p_created)::bigint);
  hm text;
  lasted text;
  m int;
  inv text := nullif(d->>'inverter', '');
  -- 0233: a bare serial reads as the email does, "Inverter 2504193036"
  inv_name text := case when inv ~ '^[0-9]+$' then 'Inverter ' || inv else inv end;
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
      title := case when inv is null then 'No readings' else 'No readings from ' || inv_name end;   -- 0233
      body := 'Since ' || hm || '.';
    when 'logger_back' then
      title := case when inv is null then 'Readings back' else 'Readings back from ' || inv_name end;   -- 0233
      body := 'No readings for ' || lasted || '.';                                                      -- 0233
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
