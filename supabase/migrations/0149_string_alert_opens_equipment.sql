-- ============================================================================
-- 0149 — A dead-string alert opens Equipment (SOLAR-339).
--
-- alert_text (0137) sent string_dead's pop-up and bell item to Solar, which shows no
-- strings; they are on Equipment, where the email's button already goes. tab is
-- worked out on each read, so alerts already in the list move too.
-- Only that line differs from 0137; create or replace keeps 0124's revoke.
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
              when p_kind = 'string_dead' then 'inverters'
              when p_kind in ('batt_hot', 'bank_drift') then 'inverters'
              else 'live' end;
  return jsonb_build_object(
    'title', title, 'body', body, 'at', ev, 'tab', tab, 'switch', private.email_switch(p_kind),
    'day', to_char(to_timestamp(ev) at time zone p_tz, 'YYYY-MM-DD'),
    'time', to_char(to_timestamp(ev) at time zone p_tz, 'HH24:MI'));
end $$;
