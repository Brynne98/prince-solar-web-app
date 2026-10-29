-- SOLAR-231 phase 2: warning emails that were wrong, found by scripts/sql/warning-tests.sql.
--
-- 1. Battery hot at the app's level: over 45 C for 3 minutes in a row, ends at 43 C or
--    below. Was one minute over 40 C (the app said hot only over 45), so a single warm
--    sample sent an email the app did not agree with.
-- 2. No readings from one inverter: each inverter's own newest reading is kept, and one
--    quiet for 15 minutes while another on the plant still reports gets its own
--    logger_stale (data.inverter set), then logger_back when it returns. Was the plant's
--    newest reading only, so a dead slave beside a live master never emailed. A whole
--    plant gone quiet keeps its one plant email.
-- 3. SunSynk down needs every login tried to be failing when there are fewer than 3, and
--    3 or more failing (over half) otherwise. Was 3 failing always, which 1 or 2 logins
--    can never reach.
-- email_hot_days counts days over 45 C to match.

alter table private.plant_alert_state add column if not exists hot_run_n int not null default 0;

create table if not exists private.inverter_alert_state (
  plant_id   bigint not null references public.plant_config (plant_id) on delete cascade,
  sn         text not null,
  last_dev   bigint,                    -- newest SunSynk device time from this inverter, epoch
  stale      boolean not null default false,
  stale_key  text,
  primary key (plant_id, sn)
);

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

  -- Grid. Unknown minutes (no voltage reported) are skipped.
  if present is not null then
    if present is distinct from s.grid_run_on then
      s.grid_run_on := present; s.grid_run_n := 1; s.grid_run_start := p_ts;
    else
      s.grid_run_n := s.grid_run_n + 1;
    end if;
    if s.grid_on is distinct from s.grid_run_on and s.grid_run_n >= (case when s.grid_run_on then 2 else 3 end) then
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
  if dev is not null and dev > coalesce(s.last_dev, 0) then
    s.last_dev := dev;
    if s.stale and extract(epoch from now()) - dev <= 900 then
      if s.stale_key is not null then
        perform private.email_enqueue_plant(p_plant, 'logger_back', 'logger_back:' || substr(s.stale_key, 14),
          jsonb_build_object('since', split_part(s.stale_key, ':', 3)::bigint, 'at', dev), s.stale_key);
      end if;
      s.stale := false; s.stale_key := null;
    end if;
  end if;

  -- Battery temperature: the hottest inverter this minute, over 45 C (unrounded, as the
  -- app judges it) for 3 minutes in a row. A minute with no temperature, or a gap of
  -- more than 2 minutes, starts the count again.
  if (f->>'has_batt')::boolean and temp is not null then
    s.hot_run_n := case when temp <= 45 then 0
                        when p_ts - coalesce(s.hot_at, 0) <= 120 then s.hot_run_n + 1 else 1 end;
    s.hot_temp := round(temp); s.hot_at := p_ts;
    if not s.hot and s.hot_run_n >= 3 then
      s.hot := true; s.hot_since := p_ts - 120; s.hot_n := 1; s.hot_sent_at := now();
      perform private.email_enqueue_plant(p_plant, 'batt_hot', 'batt_hot:' || p_plant || ':' || s.hot_since || ':1',
        jsonb_build_object('at', p_ts, 'tempC', round(temp)));
    elsif s.hot and temp <= 43 then
      s.hot := false;
    end if;
  end if;

  -- Charge spread between inverters' own batteries.
  if (f->>'has_batt')::boolean and not (f->>'shared')::boolean then
    if spread is not null then
      if spread >= 10 then
        s.drift_run_start := coalesce(s.drift_run_start, p_ts);
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
        if s.drift and spread < 8 then s.drift := false; end if;
      end if;
    end if;
  elsif s.drift or s.drift_run_start is not null then
    s.drift := false; s.drift_run_start := null;
  end if;

  s.stepped_ts := p_ts;
  update private.plant_alert_state set
    grid_on = s.grid_on, grid_since = s.grid_since, grid_off_key = s.grid_off_key,
    grid_run_on = s.grid_run_on, grid_run_n = s.grid_run_n, grid_run_start = s.grid_run_start,
    last_dev = s.last_dev, stale = s.stale, stale_key = s.stale_key,
    hot = s.hot, hot_since = s.hot_since, hot_temp = s.hot_temp, hot_at = s.hot_at, hot_sent_at = s.hot_sent_at, hot_n = s.hot_n,
    hot_run_n = s.hot_run_n,
    drift = s.drift, drift_run_start = s.drift_run_start, drift_since = s.drift_since, drift_banks = s.drift_banks,
    drift_sent_at = s.drift_sent_at, drift_n = s.drift_n, stepped_ts = s.stepped_ts
  where plant_id = p_plant;
end $$;

create or replace function public.email_poll_step(p_ts bigint, p_outcomes jsonb, p_plants bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  todo bigint[];
  r record;
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
  -- never has; SOLAR-188).
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
    dead       = st.dead and excluded.last_alive is null;
  -- Strings dead in the sun for 12 samples: one email each.
  for r in
    select a.plant_id, a.sn, a.no, coalesce(a.last_alive + 60, p_ts - 900) as since,
           coalesce(nullif(m.alias, ''), 'Inverter ' || a.sn) as inverter
      from private.string_alert_state a left join private.meta m on m.sn = a.sn
     where a.plant_id = any (todo) and not a.dead and a.dead_n >= 12
     order by a.plant_id, m.ord nulls last, a.sn, a.no
  loop
    update private.string_alert_state set dead = true, dead_since = r.since, sent_at = now(), n = 1
     where plant_id = r.plant_id and sn = r.sn and no = r.no;
    perform private.email_enqueue_plant(r.plant_id, 'string_dead',
      'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.since || ':1',
      jsonb_build_object('string', 'String ' || r.no, 'inverter', r.inverter, 'since', r.since));
  end loop;

  -- Each inverter's own newest reading (0119). One that was quiet and reports again
  -- gets its Readings back.
  for r in
    with d as (
      select x.plant_id, x.sn,
             max(extract(epoch from (x.device_time::timestamp at time zone coalesce(c.timezone, 'Africa/Johannesburg')))::bigint) as dev
        from public.readings x join public.plant_config c on c.plant_id = x.plant_id
       where x.plant_id = any (todo) and x.ts = p_ts and x.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
       group by x.plant_id, x.sn
    )
    insert into private.inverter_alert_state as s (plant_id, sn, last_dev)
    select plant_id, sn, dev from d
    on conflict (plant_id, sn) do update set last_dev = greatest(s.last_dev, excluded.last_dev)
    returning s.plant_id, s.sn, s.last_dev, s.stale, s.stale_key
  loop
    if r.stale and extract(epoch from now()) - r.last_dev <= 900 then
      perform private.email_enqueue_plant(r.plant_id, 'logger_back', 'logger_back:' || substr(r.stale_key, 14),
        jsonb_build_object('since', split_part(r.stale_key, ':', 4)::bigint, 'at', r.last_dev,
                           'inverter', coalesce((select nullif(m.alias, '') from private.meta m where m.sn = r.sn), 'Inverter ' || r.sn)),
        r.stale_key);
      update private.inverter_alert_state set stale = false, stale_key = null where plant_id = r.plant_id and sn = r.sn;
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

revoke all on function public.email_poll_step(bigint, jsonb, bigint[]) from public, anon, authenticated;
grant execute on function public.email_poll_step(bigint, jsonb, bigint[]) to service_role;

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
  n_rem int := 0;
  n_rep int := 0;
begin
  select * into sys from private.email_system_state where id = 1 for update;

  -- SunSynk itself. A login counts when poll tried it in the last 10 minutes; it is
  -- failing when its last try was SunSynk's fault and nothing good came for 10 min.
  -- Down: over half failing, and at least 3 of them, or all of them when fewer than 3
  -- were tried (0119).
  select count(*) filter (where a.last_try_at > now() - interval '10 minutes'),
         count(*) filter (where a.last_try_at > now() - interval '3 minutes' and a.last_try = 'sunsynk'
                            and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes')
    into tried, failing
    from private.sunsynk_accounts a where a.status = 'active';
  down := failing >= least(3, tried) and failing > 0 and failing * 2 > tried;

  if down and not sys.sunsynk_down then
    sys.sunsynk_down := true; sys.outage_id := sys.outage_id + 1;
    sys.down_since := (select extract(epoch from min(coalesce(a.last_ok_at, a.linked_at)))::bigint
                         from private.sunsynk_accounts a
                        where a.status = 'active' and a.last_try = 'sunsynk' and a.last_try_at > now() - interval '3 minutes'
                          and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes');
  elsif not down and sys.sunsynk_down then
    -- Back: everyone told it was down hears it is back.
    insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
    select q.user_id, q.plant_id, 'sunsynk_back', 'sunsynk_back:' || sys.outage_id, q.key,
           jsonb_build_object('since', sys.down_since, 'at', now_s), 0
      from public.email_queue q
     where q.key = 'sunsynk_down:' || sys.outage_id
    on conflict do nothing;
    sys.sunsynk_down := false; sys.up_at := now();
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
         up_at = sys.up_at
   where id = 1;

  -- No readings: 15 min since SunSynk's newest reading for the plant, while poll
  -- still tries a login on it (ours not running is not the inverter going quiet),
  -- and not during a SunSynk outage (that has its own email) nor in the 15 min
  -- after one, while readings that the outage held up come back.
  if not sys.sunsynk_down and (sys.up_at is null or sys.up_at < now() - interval '15 minutes') then
    for r in
      select s.plant_id, s.last_dev from private.plant_alert_state s
       where not s.stale and s.last_dev < now_s - 900
         and exists (select 1 from public.plant_users pu join private.sunsynk_accounts a on a.id = pu.account_id
                      where pu.plant_id = s.plant_id and a.status = 'active' and a.last_try in ('ok', 'sunsynk')
                        and a.last_try_at > now() - interval '3 minutes')
       for update of s skip locked
    loop
      update private.plant_alert_state set stale = true, stale_key = 'logger_stale:' || r.plant_id || ':' || r.last_dev
       where plant_id = r.plant_id;
      perform private.email_enqueue_plant(r.plant_id, 'logger_stale', 'logger_stale:' || r.plant_id || ':' || r.last_dev,
        jsonb_build_object('since', r.last_dev));
      n_stale := n_stale + 1;
    end loop;
    -- One inverter quiet for 15 min while another on the plant still reports (0119).
    -- An inverter no longer on the plant is left alone.
    for r in
      select i.plant_id, i.sn, i.last_dev, coalesce(nullif(m.alias, ''), 'Inverter ' || i.sn) as inverter
        from private.inverter_alert_state i
        join private.plant_alert_state s on s.plant_id = i.plant_id
        left join private.meta m on m.sn = i.sn
       where not i.stale and i.last_dev < now_s - 900
         and not s.stale and s.last_dev >= now_s - 900
         and exists (select 1 from private.inverters v where v.sn = i.sn and v.plant_id = i.plant_id)
         and exists (select 1 from public.plant_users pu join private.sunsynk_accounts a on a.id = pu.account_id
                      where pu.plant_id = i.plant_id and a.status = 'active' and a.last_try in ('ok', 'sunsynk')
                        and a.last_try_at > now() - interval '3 minutes')
       for update of i skip locked
    loop
      update private.inverter_alert_state set stale = true, stale_key = 'logger_stale:' || r.plant_id || ':' || r.sn || ':' || r.last_dev
       where plant_id = r.plant_id and sn = r.sn;
      perform private.email_enqueue_plant(r.plant_id, 'logger_stale', 'logger_stale:' || r.plant_id || ':' || r.sn || ':' || r.last_dev,
        jsonb_build_object('since', r.last_dev, 'inverter', r.inverter));
      n_stale := n_stale + 1;
    end loop;
  end if;

  -- Daily reminders while a problem lasts.
  for r in select plant_id, hot_since, hot_n, hot_temp, hot_at from private.plant_alert_state
            where hot and hot_sent_at < now() - interval '24 hours' for update skip locked loop
    update private.plant_alert_state set hot_sent_at = now(), hot_n = hot_n + 1 where plant_id = r.plant_id;
    perform private.email_enqueue_plant(r.plant_id, 'batt_hot', 'batt_hot:' || r.plant_id || ':' || r.hot_since || ':' || (r.hot_n + 1),
      jsonb_build_object('at', r.hot_at, 'tempC', r.hot_temp, 'since', r.hot_since));
    n_rem := n_rem + 1;
  end loop;
  for r in select plant_id, drift_since, drift_n, drift_banks from private.plant_alert_state
            where drift and drift_sent_at < now() - interval '24 hours' for update skip locked loop
    update private.plant_alert_state set drift_sent_at = now(), drift_n = drift_n + 1 where plant_id = r.plant_id;
    perform private.email_enqueue_plant(r.plant_id, 'bank_drift', 'bank_drift:' || r.plant_id || ':' || r.drift_since || ':' || (r.drift_n + 1),
      jsonb_build_object('since', r.drift_since, 'banks', r.drift_banks));
    n_rem := n_rem + 1;
  end loop;
  for r in select a.plant_id, a.sn, a.no, a.dead_since, a.n, coalesce(nullif(m.alias, ''), 'Inverter ' || a.sn) as inverter
             from private.string_alert_state a left join private.meta m on m.sn = a.sn
            where a.dead and a.sent_at < now() - interval '24 hours' for update of a skip locked loop
    update private.string_alert_state set sent_at = now(), n = n + 1 where plant_id = r.plant_id and sn = r.sn and no = r.no;
    perform private.email_enqueue_plant(r.plant_id, 'string_dead',
      'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.dead_since || ':' || (r.n + 1),
      jsonb_build_object('string', 'String ' || r.no, 'inverter', r.inverter, 'since', r.dead_since));
    n_rem := n_rem + 1;
  end loop;

  -- Reports from 07:00 local: weekly on Monday, monthly on the 1st, yearly on 1 January.
  with loc as (
    select pu.user_id, pu.plant_id, timezone(public.plant_tz(pu.plant_id), now()) as t
      from public.plant_users pu
  ), due as (
    select user_id, plant_id, t::date as d, p.period
      from loc, lateral (values ('week'), ('month'), ('year')) p(period)
     where extract(hour from t) >= 7
       and case p.period when 'week'  then extract(isodow from t) = 1
                         when 'month' then extract(day from t) = 1
                         else extract(day from t) = 1 and extract(month from t) = 1 end
  ), ins as (
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    select user_id, plant_id, 'report_' || period, 'report_' || period || ':' || plant_id || ':' || d,
           jsonb_build_object('today', d), 2
      from due
    on conflict do nothing
    returning 1
  )
  select count(*) into n_rep from ins;

  return jsonb_build_object('sunsynkDown', sys.sunsynk_down, 'tried', tried, 'failing', failing,
                            'stale', n_stale, 'reminders', n_rem, 'reports', n_rep);
end $$;

create or replace function public.email_hot_days(p_plant bigint)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(distinct (timezone(public.plant_tz(p_plant), to_timestamp(h.ts)))::date)::int
    from public.readings h
   where h.plant_id = p_plant and h.ts >= extract(epoch from now())::bigint - 30 * 86400
     and h.batt_temp_c > 45 and h.batt_temp_c < 80
$$;
