-- ============================================================================
-- 0151 — One alert and one "back to normal" note per problem (SOLAR-320).
--
-- A value that bounced round a limit could send the same alert again and again: on
-- 31 Oct 495944's slave sent No readings 12:48, back 12:57, No readings 13:15, back
-- 16:04, to both owners. Now:
--
--   Hold      the "back" note goes only once the problem has stayed clear for 15 min
--             (grid: 5 known minutes with grid). If it comes back inside that time it
--             is the same problem still: no new alert, no "back" yet.
--               grid           back after 5 minutes on (was 2), once a Grid off went out
--               readings       back once readings have come for 15 min with no gap over
--                              10 min, by SunSynk's clock (plant and each inverter)
--               SunSynk        back once not down for 15 min
--               battery hot    back after 15 min at 43 °C or below
--               uneven charge  back after 15 min under 8 points apart
--               panels         back after 15 min with voltage and no dead sample
--   New       batt_hot_back, bank_drift_back, string_back: the three alerts that had
--             no "back" note. Each carries since (alert start), at (when it went
--             normal) and the reading then. Their pair_key is the alert's first key, so
--             a pop-up "back" waits for its alert's pop-up (push_claim, 0124).
--   Dropped   the once-a-day repeat of battery hot, uneven charge and panels stopped.
--             The "back" note says when it is over (decided 2026-11-05).
--
-- Bodies: email_plant_apply and email_poll_step are 0119's, email_sweep 0142's,
-- alert_text 0149's, api_notifications 0148's, with only the parts above changed.
-- The alert kind lists in api_notifications and api_notifications_read now read
-- private.is_alert, so a new kind goes in one place.
-- ============================================================================

alter table private.plant_alert_state
  add column if not exists stale_clear_at bigint,   -- readings: start of the current run of fresh readings while stale
  add column if not exists hot_clear_at   bigint,   -- first minute of the current run at 43 °C or below while hot
  add column if not exists drift_clear_at bigint;   -- first minute of the current run under 8 points while drift
alter table private.inverter_alert_state
  add column if not exists clear_at bigint;         -- as stale_clear_at, for one inverter
alter table private.string_alert_state
  add column if not exists clear_at bigint;         -- first sample with voltage since the last dead one, while dead
alter table private.email_system_state
  add column if not exists clear_since timestamptz; -- SunSynk: first sweep not down, while an outage is open

-- ---------------------------------------------------------------------------
-- Kinds
-- ---------------------------------------------------------------------------
create or replace function private.is_alert(p_kind text)
returns boolean language sql immutable as $$
  select p_kind in ('grid_down', 'grid_back', 'batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back',
                    'string_dead', 'string_back', 'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back')
$$;

drop index if exists public.email_queue_alerts_idx;
create index email_queue_alerts_idx on public.email_queue (user_id, created_at desc)
  where kind in ('grid_down', 'grid_back', 'batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back',
                 'string_dead', 'string_back', 'logger_stale', 'logger_back', 'sunsynk_down', 'sunsynk_back');

create or replace function private.email_switch(p_kind text)
returns text language sql immutable as $$
  select case
    when p_kind in ('grid_down', 'grid_back') then 'grid'
    when p_kind in ('batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back') then 'battery'
    when p_kind in ('string_dead', 'string_back') then 'panels'
    when p_kind in ('logger_stale', 'logger_back') then 'readings'
    when p_kind in ('sunsynk_down', 'sunsynk_back') then 'sunsynk'
    when p_kind = 'report_week' then 'weekly'
    when p_kind = 'report_month' then 'monthly'
    when p_kind = 'report_year' then 'yearly'
  end
$$;

-- ---------------------------------------------------------------------------
-- One plant at one minute
-- ---------------------------------------------------------------------------
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
        perform private.email_enqueue_plant(p_plant, 'grid_down', k, jsonb_build_object(
          'since', s.grid_run_start,
          'chargePct', (select round(a.soc)::int from public.agg_minute a
                         where a.plant_id = p_plant and a.ts between p_ts - 600 and p_ts and a.soc is not null
                         order by a.ts desc limit 1)));
        s.grid_off_key := k;
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

-- ---------------------------------------------------------------------------
-- Every plant polled this minute
-- ---------------------------------------------------------------------------
create or replace function public.email_poll_step(p_ts bigint, p_outcomes jsonb, p_plants bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  todo bigint[];
  r record;
  clr bigint;
  failed jsonb := '[]'::jsonb;
begin
  update private.sunsynk_accounts a set last_try_at = now(), last_try = o.outcome
    from jsonb_to_recordset(coalesce(p_outcomes, '[]'::jsonb)) as o(account uuid, outcome text)
   where a.id = o.account and o.outcome in ('ok', 'sunsynk', 'ours');

  -- Plants with config (purged ones have none) not already stepped for this minute.
  -- The rows stay locked to the end, so a link kick polling the same account in the
  -- same minute waits here and then finds them stepped: strings are counted once.
  insert into private.plant_alert_state (plant_id)
  select c.plant_id from public.plant_config c where c.plant_id = any (coalesce(p_plants, '{}')) order by 1
  on conflict do nothing;
  select coalesce(array_agg(x.plant_id), '{}') into todo
    from (select s.plant_id from private.plant_alert_state s
           where s.plant_id = any (coalesce(p_plants, '{}')) and (s.stepped_ts is null or s.stepped_ts < p_ts)
           order by s.plant_id for update) x;

  -- Strings, all plants at once: a string with voltage is alive; one under 1.5 V and
  -- 5 W while another string on its inverter makes over 200 W counts a dead sample,
  -- but only once the string itself has made over 200 W (an input with no panels
  -- never has; SOLAR-188). A dead string stays dead until it has had voltage for
  -- 15 min with no dead sample (clear_at, 0151).
  insert into private.string_alert_state as st (plant_id, sn, no, last_alive, dead_n, made_power)
  select x.plant_id, x.sn, x.no, case when x.alive then p_ts end, 0, x.made
    from (select s.plant_id, s.sn, s.no, coalesce(s.volt_v, 0) >= 1.5 as alive,
                 coalesce(s.power_w, 0) > 200 as made,
                 coalesce(s.volt_v, 0) < 1.5 and coalesce(s.power_w, 0) < 5
                   and exists (select 1 from public.strings o where o.plant_id = s.plant_id and o.ts = p_ts and o.sn = s.sn
                                  and o.no <> s.no and coalesce(o.power_w, 0) > 200) as dead_in_sun
            from public.strings s
           where s.plant_id = any (todo) and s.ts = p_ts) x
   where x.alive or x.dead_in_sun
  on conflict (plant_id, sn, no) do update set
    last_alive = coalesce(excluded.last_alive, st.last_alive),
    made_power = st.made_power or excluded.made_power,
    dead_n     = case when excluded.last_alive is not null or not st.made_power then 0
                      when st.dead then st.dead_n else st.dead_n + 1 end,
    clear_at   = case when st.dead and excluded.last_alive is not null then coalesce(st.clear_at, excluded.last_alive) end;
  -- Strings dead in the sun for 12 samples: one email each.
  for r in
    select a.plant_id, a.sn, a.no, coalesce(a.last_alive + 60, p_ts - 900) as since,
           coalesce(nullif(m.alias, ''), 'Inverter ' || a.sn) as inverter
      from private.string_alert_state a left join private.meta m on m.sn = a.sn
     where a.plant_id = any (todo) and not a.dead and a.dead_n >= 12
     order by a.plant_id, m.ord nulls last, a.sn, a.no
  loop
    update private.string_alert_state set dead = true, dead_since = r.since, sent_at = now(), n = 1, clear_at = null
     where plant_id = r.plant_id and sn = r.sn and no = r.no;
    perform private.email_enqueue_plant(r.plant_id, 'string_dead',
      'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.since || ':1',
      jsonb_build_object('string', 'String ' || r.no, 'inverter', r.inverter, 'since', r.since));
  end loop;
  -- Dead strings with voltage for 15 min: one "back" each. It goes on a minute with
  -- voltage, so one stray sample before nightfall cannot send it overnight.
  for r in
    select a.plant_id, a.sn, a.no, a.dead_since, a.clear_at,
           coalesce(nullif(m.alias, ''), 'Inverter ' || a.sn) as inverter
      from private.string_alert_state a left join private.meta m on m.sn = a.sn
     where a.plant_id = any (todo) and a.dead and p_ts - a.clear_at >= 900 and a.last_alive = p_ts
     order by a.plant_id, m.ord nulls last, a.sn, a.no
  loop
    update private.string_alert_state set dead = false, dead_n = 0, clear_at = null
     where plant_id = r.plant_id and sn = r.sn and no = r.no;
    perform private.email_enqueue_plant(r.plant_id, 'string_back',
      'string_back:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.dead_since,
      jsonb_build_object('string', 'String ' || r.no, 'inverter', r.inverter, 'since', r.dead_since, 'at', r.clear_at),
      'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.dead_since || ':1');
  end loop;

  -- Each inverter's own newest reading (0119). One that was quiet gets its Readings
  -- back once it has reported for 15 min with no gap over 10 min (0151).
  for r in
    with d as (
      select x.plant_id, x.sn,
             max(extract(epoch from (x.device_time::timestamp at time zone coalesce(c.timezone, 'Africa/Johannesburg')))::bigint) as dev
        from public.readings x join public.plant_config c on c.plant_id = x.plant_id
       where x.plant_id = any (todo) and x.ts = p_ts and x.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
       group by x.plant_id, x.sn
    )
    select d.plant_id, d.sn, d.dev, s.last_dev as prev, s.stale, s.stale_key, s.clear_at
      from d left join private.inverter_alert_state s on s.plant_id = d.plant_id and s.sn = d.sn
  loop
    if r.prev is null then
      insert into private.inverter_alert_state as s (plant_id, sn, last_dev) values (r.plant_id, r.sn, r.dev)
      on conflict (plant_id, sn) do update set last_dev = greatest(s.last_dev, excluded.last_dev);
    elsif r.dev > r.prev then
      clr := case when r.stale then case when r.clear_at is null or r.dev - r.prev > 600 then r.dev else r.clear_at end end;
      if r.stale and extract(epoch from now()) - r.dev <= 900 and r.dev - clr >= 900 then
        perform private.email_enqueue_plant(r.plant_id, 'logger_back', 'logger_back:' || substr(r.stale_key, 14),
          jsonb_build_object('since', split_part(r.stale_key, ':', 4)::bigint, 'at', clr,
                             'inverter', coalesce((select nullif(m.alias, '') from private.meta m where m.sn = r.sn), 'Inverter ' || r.sn)),
          r.stale_key);
        update private.inverter_alert_state set last_dev = r.dev, stale = false, stale_key = null, clear_at = null
         where plant_id = r.plant_id and sn = r.sn;
      else
        update private.inverter_alert_state set last_dev = r.dev, clear_at = clr where plant_id = r.plant_id and sn = r.sn;
      end if;
    end if;
  end loop;

  -- Everything else from one read of the minute's readings. Grid present is
  -- q_grid_present's rule (0055): over 100 V among the rows with the newest
  -- device_time; null when nobody reported a voltage.
  for r in
    with rd as (
      select x.plant_id, x.sn, x.device_time, x.grid_volt_v, x.batt_temp_c, x.batt_soc
        from public.readings x where x.plant_id = any (todo) and x.ts = p_ts
    ), newest as (
      select plant_id, max(device_time) as dt from rd where grid_volt_v is not null group by plant_id
    )
    select c.plant_id, jsonb_build_object(
             'present', case when count(rd.grid_volt_v) = 0 then null
                             else coalesce(bool_or(rd.grid_volt_v > 100) filter (
                                    where rd.grid_volt_v is not null and rd.device_time is not distinct from n.dt), false) end,
             'dev', max(case when rd.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                             then extract(epoch from (rd.device_time::timestamp at time zone coalesce(c.timezone, 'Africa/Johannesburg')))::bigint end),
             'temp', max(rd.batt_temp_c) filter (where rd.batt_temp_c > 0 and rd.batt_temp_c < 80),
             'spread', case when count(distinct rd.sn) filter (where rd.batt_soc between 1 and 100) >= 2
                            then max(rd.batt_soc) filter (where rd.batt_soc between 1 and 100)
                               - min(rd.batt_soc) filter (where rd.batt_soc between 1 and 100) end,
             'has_batt', coalesce(c.has_battery, true),
             'shared', coalesce(c.battery_banks = 'shared', false)) as f
      from public.plant_config c
      join rd on rd.plant_id = c.plant_id
      left join newest n on n.plant_id = c.plant_id
     where c.plant_id = any (todo)
     group by c.plant_id, c.timezone, c.has_battery, c.battery_banks
  loop
    begin
      perform private.email_plant_apply(r.plant_id, p_ts, r.f);
    exception when others then
      failed := failed || jsonb_build_object('plant', r.plant_id, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('plants', coalesce(array_length(todo, 1), 0), 'failed', failed);
end $$;

-- ---------------------------------------------------------------------------
-- What only the clock can tell
-- ---------------------------------------------------------------------------
create or replace function public.email_sweep()
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  now_s bigint := extract(epoch from now())::bigint;
  sys private.email_system_state;
  tried int;
  failing int;
  down boolean;
  r record;
  n_stale int := 0;
  n_rep int := 0;
begin
  select * into sys from private.email_system_state where id = 1 for update;

  -- SunSynk itself. A login counts when poll tried it in the last 10 minutes; it is
  -- failing when its last try was SunSynk's fault and nothing good came for 10 min.
  -- Down: over half failing, and at least 3 of them, or all of them when fewer than 3
  -- were tried (0119). Back once not down for 15 min (0151).
  select count(*) filter (where a.last_try_at > now() - interval '10 minutes'),
         count(*) filter (where a.last_try_at > now() - interval '3 minutes' and a.last_try = 'sunsynk'
                            and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes')
    into tried, failing
    from private.sunsynk_accounts a where a.status = 'active';
  down := failing >= least(3, tried) and failing > 0 and failing * 2 > tried;

  if down and not sys.sunsynk_down then
    sys.sunsynk_down := true; sys.outage_id := sys.outage_id + 1; sys.clear_since := null;
    sys.down_since := (select extract(epoch from min(coalesce(a.last_ok_at, a.linked_at)))::bigint
                         from private.sunsynk_accounts a
                        where a.status = 'active' and a.last_try = 'sunsynk' and a.last_try_at > now() - interval '3 minutes'
                          and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes');
  elsif down then
    sys.clear_since := null;
  elsif sys.sunsynk_down then
    sys.clear_since := coalesce(sys.clear_since, now());
    if sys.clear_since <= now() - interval '15 minutes' then
      -- Back: everyone told it was down hears it is back.
      insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
      select q.user_id, q.plant_id, 'sunsynk_back', 'sunsynk_back:' || sys.outage_id, q.key,
             jsonb_build_object('since', sys.down_since, 'at', extract(epoch from sys.clear_since)::bigint), 0
        from public.email_queue q
       where q.key = 'sunsynk_down:' || sys.outage_id
      on conflict do nothing;
      sys.sunsynk_down := false; sys.up_at := now(); sys.clear_since := null;
    end if;
  end if;
  if sys.sunsynk_down then
    -- Users on a failing login; one email each, about their first plant on it.
    -- Run every minute of the outage, so a login that fails later is told too.
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    select distinct on (pu.user_id) pu.user_id, pu.plant_id, 'sunsynk_down', 'sunsynk_down:' || sys.outage_id,
           jsonb_build_object('since', sys.down_since), 0
      from private.sunsynk_accounts a join public.plant_users pu on pu.account_id = a.id
     where a.status = 'active' and a.last_try = 'sunsynk' and a.last_try_at > now() - interval '3 minutes'
       and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes'
     order by pu.user_id, pu.linked_at
    on conflict do nothing;
  end if;
  update private.email_system_state set sunsynk_down = sys.sunsynk_down, outage_id = sys.outage_id, down_since = sys.down_since,
         up_at = sys.up_at, clear_since = sys.clear_since
   where id = 1;

  -- No readings: 30 min since SunSynk's newest reading for the plant, while poll
  -- still tries a login on it (ours not running is not the inverter going quiet),
  -- and not during a SunSynk outage (that has its own email) nor in the 15 min
  -- after one, while readings that the outage held up come back.
  if not sys.sunsynk_down and (sys.up_at is null or sys.up_at < now() - interval '15 minutes') then
    for r in
      select s.plant_id, s.last_dev from private.plant_alert_state s
       where not s.stale and s.last_dev < now_s - 1800
         and exists (select 1 from public.plant_users pu join private.sunsynk_accounts a on a.id = pu.account_id
                      where pu.plant_id = s.plant_id and a.status = 'active' and a.last_try in ('ok', 'sunsynk')
                        and a.last_try_at > now() - interval '3 minutes')
       for update of s skip locked
    loop
      update private.plant_alert_state set stale = true, stale_key = 'logger_stale:' || r.plant_id || ':' || r.last_dev,
             stale_clear_at = null
       where plant_id = r.plant_id;
      perform private.email_enqueue_plant(r.plant_id, 'logger_stale', 'logger_stale:' || r.plant_id || ':' || r.last_dev,
        jsonb_build_object('since', r.last_dev));
      n_stale := n_stale + 1;
    end loop;
    -- One inverter quiet for 30 min while another on the plant still reports (0119).
    -- An inverter no longer on the plant is left alone.
    for r in
      select i.plant_id, i.sn, i.last_dev, coalesce(nullif(m.alias, ''), 'Inverter ' || i.sn) as inverter
        from private.inverter_alert_state i
        join private.plant_alert_state s on s.plant_id = i.plant_id
        left join private.meta m on m.sn = i.sn
       where not i.stale and i.last_dev < now_s - 1800
         and not s.stale and s.last_dev >= now_s - 900
         and exists (select 1 from private.inverters v where v.sn = i.sn and v.plant_id = i.plant_id)
         and exists (select 1 from public.plant_users pu join private.sunsynk_accounts a on a.id = pu.account_id
                      where pu.plant_id = i.plant_id and a.status = 'active' and a.last_try in ('ok', 'sunsynk')
                        and a.last_try_at > now() - interval '3 minutes')
       for update of i skip locked
    loop
      update private.inverter_alert_state set stale = true, stale_key = 'logger_stale:' || r.plant_id || ':' || r.sn || ':' || r.last_dev,
             clear_at = null
       where plant_id = r.plant_id and sn = r.sn;
      perform private.email_enqueue_plant(r.plant_id, 'logger_stale', 'logger_stale:' || r.plant_id || ':' || r.sn || ':' || r.last_dev,
        jsonb_build_object('since', r.last_dev, 'inverter', r.inverter));
      n_stale := n_stale + 1;
    end loop;
  end if;

  -- No once-a-day repeat while battery hot, uneven charge or panels stopped last: each
  -- has its "back" note now (0151).

  -- Reports from 07:00 local: weekly on Monday, monthly on the 1st, yearly on 1 January,
  -- for plants linked by the first day of the period they cover (private.reports_due).
  with ins as (
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    select user_id, plant_id, 'report_' || period, 'report_' || period || ':' || plant_id || ':' || d,
           jsonb_build_object('today', d), 2
      from private.reports_due(now())
    on conflict do nothing
    returning 1
  )
  select count(*) into n_rep from ins;

  return jsonb_build_object('sunsynkDown', sys.sunsynk_down, 'tried', tried, 'failing', failing,
                            'stale', n_stale, 'reports', n_rep);
end $$;

-- ---------------------------------------------------------------------------
-- Bell and pop-up text
-- ---------------------------------------------------------------------------
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
      body := (d->>'string') || ' on ' || (d->>'inverter') || '. The other panels are OK.';
    when 'string_back' then
      title := 'Panels producing again';
      body := (d->>'string') || ' on ' || (d->>'inverter') || ', after ' || lasted || ' without power.';
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

-- ---------------------------------------------------------------------------
-- The list: 0148's and 0124's, reading private.is_alert for the kinds
-- ---------------------------------------------------------------------------
create or replace function public.api_notifications()
returns jsonb language sql stable security definer set search_path = '' as $$
  with n as (
    select q.id, q.kind, q.plant_id, pu.plant_name, q.read_at, q.created_at,
           private.alert_text(q.kind, q.data, q.created_at, public.plant_tz(q.plant_id)) t
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid()
       and private.is_alert(q.kind)
       and q.created_at > now() - interval '30 days'
     order by q.created_at desc, q.id desc
     limit 300)
  select jsonb_build_object(
    'pinned', private.billing_notices(),
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
     and private.is_alert(kind)
     and (p_ids is null or id = any (p_ids));
$$;
