-- ============================================================================
-- 0153 — One way to say a duration and a string (SOLAR-348).
--
-- Pop-up alerts said "1 h 33 min" and "String 2 on Inverter X"; the app and the
-- emails say "1h 33m" and "Inverter X, string 2". alert_text (0151's) now says the
-- same: 45 min, 1h 33m, 2h. Nothing else in it changes. Sends nothing.
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
      body := 'Off since ' || hm || '.' || coalesce(' Battery ' || (d->>'chargePct') || '%, running the house.', '');
    when 'grid_back' then
      title := 'Grid back'; body := 'On again, after ' || lasted || ' without grid.';
    when 'batt_hot' then
      title := 'Battery hot'; body := (d->>'tempC') || ' °C. Batteries wear faster when they run hot.';
    when 'batt_hot_back' then
      title := 'Battery cooled'; body := (d->>'tempC') || ' °C, after ' || lasted || ' running hot.';
    when 'bank_drift' then
      title := 'Batteries charging unevenly';
      body := (select string_agg((b->>'name') || ' ' || (b->>'chargePct') || '%', ', ') from jsonb_array_elements(d->'banks') b)
              || '. Over an hour apart.';
    when 'bank_drift_back' then
      title := 'Batteries charging evenly';
      body := (select string_agg((b->>'name') || ' ' || (b->>'chargePct') || '%', ', ') from jsonb_array_elements(d->'banks') b)
              || ', after ' || lasted || ' apart.';
    when 'string_dead' then
      title := 'Some panels stopped producing';
      body := (d->>'inverter') || ', ' || lower(d->>'string') || '. The other panels are OK.';
    when 'string_back' then
      title := 'Panels producing again';
      body := (d->>'inverter') || ', ' || lower(d->>'string') || ', after ' || lasted || ' without power.';
    when 'logger_stale' then
      title := case when inv is null then 'No readings' else 'No readings from ' || inv end;
      body := 'No new reading for 30 minutes.' || case when inv is null then '' else ' Your other inverters are still reporting.' end;
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
              when p_kind in ('string_dead', 'string_back') then 'inverters'
              when p_kind in ('batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back') then 'inverters'
              else 'live' end;
  return jsonb_build_object(
    'title', title, 'body', body, 'at', ev, 'tab', tab, 'switch', private.email_switch(p_kind),
    'day', to_char(to_timestamp(ev) at time zone p_tz, 'YYYY-MM-DD'),
    'time', to_char(to_timestamp(ev) at time zone p_tz, 'HH24:MI'));
end $$;

