CREATE OR REPLACE FUNCTION private.email_plant_apply(p_plant bigint, p_ts bigint, f jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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
end $function$;
