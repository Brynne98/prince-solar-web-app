-- ============================================================================
-- 0154 — Shorter alert words (SOLAR-354).
--
-- Pop-ups, the bell and the Notifications page: the number or time, no reasons or
-- advice, the same words as the alert emails. Only titles and bodies change; 0153's
-- body otherwise. Sends nothing.
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
    else return null;
  end case;
  tab := case when p_kind in ('grid_down', 'grid_back') then 'grid'
              when p_kind in ('string_dead', 'string_back') then 'inverters'
              when p_kind in ('batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back') then 'inverters'
              else 'live' end;
  return jsonb_build_object(
    'title', title, 'body', body, 'at', ev, 'tab', tab, 'switch', private.email_switch(p_kind),
    'day', to_char(to_timestamp(ev) at time zone p_tz, 'YYYY-MM-DD'),
    'time', to_char(to_timestamp(ev) at time zone p_tz, 'HH24:MI'));
end $$;

