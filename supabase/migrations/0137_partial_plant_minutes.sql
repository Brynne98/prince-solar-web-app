-- SOLAR-296: one inverter gone quiet no longer drags a wrong plant total into
-- agg_minute that recover can never replace.
--
-- poll leaves out an inverter whose /realtime/input answers without a time (a quiet
-- logger gets that from SunSynk, with zeros on the other endpoints) and marks the
-- plant's row partial. Here:
--   poll_commit        stores a partial row with source 'poller_partial'
--   q_missing_minutes  counts a partial row as missing, so recover asks for it
--   q_insert_recovered replaces a partial row; every other row stays first-write-wins
--   batt_sign_detect   flips partial rows with the poller's own
-- Readers that pick source = 'poller' (recover's calibration and dry run) leave
-- partial rows out, as they should.
--
-- No readings email: sent after 30 minutes quiet, was 15 (email_sweep, alert_text).
-- Short logger drops were noise. Bodies are the latest ones (0061, 0044, 0034, 0041,
-- 0119, 0124) with only the marked lines changed.

create or replace function public.poll_commit(
  p_account   uuid,
  p_ts        bigint,
  p_readings  jsonb,
  p_strings   jsonb,
  p_agg       jsonb,
  p_meta      jsonb,
  p_inverters jsonb,
  p_access    text,
  p_expires   bigint
)
returns jsonb
language plpgsql
security definer
set search_path = pg_temp
as $$
declare
  n_readings int := 0;
  n_strings  int := 0;
  gaps       bigint[] := '{}';
  plants     bigint[] := '{}';
  a          record;
  prev_ts    bigint;
begin
  if to_regclass('pg_temp._rd') is not null then drop table _rd; end if;
  if to_regclass('pg_temp._st') is not null then drop table _st; end if;

  create temp table _rd on commit drop as
    select * from jsonb_populate_recordset(null::public.readings, coalesce(p_readings, '[]'::jsonb))
     where plant_id is not null;
  delete from public.readings r using _rd where r.ts = p_ts and r.ts = _rd.ts and r.sn = _rd.sn;
  insert into public.readings select * from _rd;
  get diagnostics n_readings = row_count;

  create temp table _st on commit drop as
    select * from jsonb_populate_recordset(null::public.strings, coalesce(p_strings, '[]'::jsonb))
     where plant_id is not null;
  -- Remember every input that has ever produced, and how many inputs each inverter
  -- reports (0061). An input that has never produced is not wired to anything: its
  -- all-zero row is dropped rather than stored every minute. An input that has
  -- produced keeps every row, zeros included, so a string that dies still shows.
  update private.meta m
     set used_strings = (select array_agg(distinct x order by x)
                           from unnest(m.used_strings || array(
                             select t.no from _st t
                              where t.sn = m.sn and private.string_live(t.volt_v, t.current_a, t.power_w, t.today_kwh))) x)
   where exists (select 1 from _st t
                  where t.sn = m.sn and not (t.no = any(m.used_strings))
                    and private.string_live(t.volt_v, t.current_a, t.power_w, t.today_kwh));
  update private.meta m set string_slots = c.n
    from (select sn, count(*)::int as n from _st group by sn) c
   where m.sn = c.sn and m.string_slots is distinct from c.n;
  delete from _st t
   where not private.string_live(t.volt_v, t.current_a, t.power_w, t.today_kwh)
     and not exists (select 1 from private.meta m where m.sn = t.sn and t.no = any(m.used_strings));
  delete from public.strings s using _st where s.ts = p_ts and s.ts = _st.ts and s.sn = _st.sn and s.no = _st.no;
  insert into public.strings select * from _st;
  get diagnostics n_strings = row_count;

  for a in
    select (r->>'plant_id')::bigint as plant_id,
           nullif(r->>'pv_w',   '')::int as pv_w,
           nullif(r->>'load_w', '')::int as load_w,
           nullif(r->>'batt_w', '')::int as batt_w,
           nullif(r->>'grid_w', '')::int as grid_w,
           nullif(r->>'soc',    '')::int as soc,
           coalesce((r->>'partial')::boolean, false) as partial
      from jsonb_array_elements(coalesce(p_agg, '[]'::jsonb)) r
     where r->>'plant_id' is not null
  loop
    plants := plants || a.plant_id;

    select max(ts) into prev_ts from public.agg_minute where plant_id = a.plant_id;
    if prev_ts is not null and p_ts - prev_ts > 90 then
      insert into private.gaps (plant_id, from_ts, to_ts) values (a.plant_id, prev_ts, p_ts)
      on conflict (plant_id, from_ts) do nothing;
      gaps := gaps || a.plant_id;
    end if;

    insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
    values (a.plant_id, p_ts, a.pv_w, a.load_w, a.batt_w, a.grid_w, a.soc,
            case when a.partial then 'poller_partial' else 'poller' end)
    on conflict (plant_id, ts) do nothing;
  end loop;

  perform public.meta_upsert(coalesce(p_meta, '[]'::jsonb));
  perform public.inverters_seed(coalesce(p_inverters, '[]'::jsonb));
  update private.sunsynk_accounts
     set access_token = p_access, access_expires_at = p_expires,
         last_ok_at = now(), last_error = null
   where id = p_account;
  -- The other logins that can see these plants were served this minute too.
  update private.sunsynk_accounts s
     set last_ok_at = now()
   where s.status = 'active' and s.id <> p_account
     and exists (select 1 from public.plant_users pu where pu.account_id = s.id and pu.plant_id = any(plants));

  return jsonb_build_object(
    'readings', n_readings,
    'strings',  n_strings,
    'plants',   to_jsonb(plants),
    'gaps',     to_jsonb(gaps));
end;
$$;

create or replace function public.q_missing_minutes(p_plant bigint, p_day date)
returns table (ts bigint) language sql stable set search_path = public, pg_temp
as $$
  with b as (
    select (select min(a.ts) from public.agg_minute a where a.plant_id = p_plant) as first_ts,
           (select public.day_start_epoch_tz(c.backfill_next, public.plant_tz(p_plant))
              from public.plant_config c where c.plant_id = p_plant and c.backfill_next is not null) as bf_ts,
           public.day_start_epoch_tz(p_day, public.plant_tz(p_plant))            as day_start,
           extract(epoch from now())::bigint                                    as now_ts
  ),
  bounds as (
    select ceil(greatest(day_start, least(first_ts, bf_ts)) / 60.0)::bigint * 60 as lo,
           least(day_start + 86400, now_ts - 600)                                as hi
      from b where first_ts is not null or bf_ts is not null
  )
  select g as ts from bounds, generate_series(bounds.lo, bounds.hi - 60, 60) g
   where bounds.hi > bounds.lo
     and not exists (select 1 from public.agg_minute a where a.plant_id = p_plant and a.ts = g
                                                  and a.source <> 'poller_partial')
   order by g
$$;

create or replace function public.q_insert_recovered(p_plant bigint, p_rows jsonb, p_source text default 'plantfeed')
returns integer
language plpgsql
set search_path = public, pg_temp
as $$
declare n integer;
begin
  if p_source not in ('plantfeed', 'invhistory') then
    raise exception 'q_insert_recovered: unknown source %', p_source;
  end if;
  with ins as (
    insert into public.agg_minute (plant_id, ts, pv_w, load_w, batt_w, grid_w, soc, source)
    select p_plant, (r->>'ts')::bigint,
           nullif(r->>'pv_w','')::integer,   nullif(r->>'load_w','')::integer,
           nullif(r->>'batt_w','')::integer, nullif(r->>'grid_w','')::integer,
           nullif(r->>'soc','')::integer,    p_source
      from jsonb_array_elements(p_rows) r
    on conflict (plant_id, ts) do update
      set pv_w = excluded.pv_w, load_w = excluded.load_w, batt_w = excluded.batt_w,
          grid_w = excluded.grid_w, soc = excluded.soc, source = excluded.source
      where agg_minute.source = 'poller_partial'
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;

create or replace function public.batt_sign_detect(p_plant bigint, p_default text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  cur      record;
  votes_c  int;
  votes_d  int;
  detected text;
  used     text;
  since    bigint;
  n_read   int := 0;
  n_agg    int := 0;
begin
  select batt_positive_means, batt_sign_source, batt_sign_updated_at into cur
    from public.plant_config where plant_id = p_plant;
  if cur.batt_sign_source = 'user' then
    return jsonb_build_object('plant', p_plant, 'skipped', 'user override');
  end if;

  -- Half an hour apart, same inverter, real (not carried) rows, battery working
  -- hard enough that SoC must move a whole percent, and power keeping one sign
  -- for the whole window. (A 26 kWh pack at 900 W moves ~0.6 %/10 min, which an
  -- integer SoC cannot show; 30 min is the shortest window that always can.)
  with r as (
    select sn, ts, batt_soc, batt_power_w,
           lag(batt_soc, 30) over w as soc0,
           lag(ts, 30)       over w as ts0,
           min(sign(batt_power_w)) over (partition by sn order by ts rows between 30 preceding and current row) as smin,
           max(sign(batt_power_w)) over (partition by sn order by ts rows between 30 preceding and current row) as smax
      from public.readings
     where plant_id = p_plant
       and ts > extract(epoch from now())::bigint - 86400
       and not carried
       and batt_soc between 1 and 100
       and batt_power_w is not null
    window w as (partition by sn order by ts)
  ),
  v as (
    select case when batt_power_w > 0 and batt_soc > soc0 then 'charging'
                when batt_power_w < 0 and batt_soc < soc0 then 'charging'
                when batt_power_w > 0 and batt_soc < soc0 then 'discharging'
                when batt_power_w < 0 and batt_soc > soc0 then 'discharging' end as vote
      from r
     where ts0 is not null and ts - ts0 between 1700 and 2100
       and abs(batt_power_w) >= 200 and smin = smax
       and abs(batt_soc - soc0) >= 1
  )
  select count(*) filter (where vote = 'charging'), count(*) filter (where vote = 'discharging')
    into votes_c, votes_d from v where vote is not null;

  if votes_c + votes_d < 6 then
    return jsonb_build_object('plant', p_plant, 'votes', jsonb_build_object('charging', votes_c, 'discharging', votes_d), 'decided', false);
  end if;
  if votes_c >= 9 * votes_d then detected := 'charging';
  elsif votes_d >= 9 * votes_c then detected := 'discharging';
  else
    return jsonb_build_object('plant', p_plant, 'votes', jsonb_build_object('charging', votes_c, 'discharging', votes_d), 'decided', false, 'reason', 'split');
  end if;

  -- What the poller has been assuming for rows since the last decision.
  used := coalesce(cur.batt_positive_means, p_default);
  since := coalesce(extract(epoch from cur.batt_sign_updated_at)::bigint, 0);

  if detected is distinct from used then
    update public.readings set batt_w = -batt_w
     where plant_id = p_plant and ts >= since and batt_w is not null;
    get diagnostics n_read = row_count;
    update public.agg_minute set batt_w = -batt_w
     where plant_id = p_plant and ts >= since and source in ('poller', 'poller_partial') and batt_w is not null;
    get diagnostics n_agg = row_count;
  end if;

  update public.plant_config
     set batt_positive_means = detected, batt_sign_source = 'detected', batt_sign_updated_at = now()
   where plant_id = p_plant;

  return jsonb_build_object('plant', p_plant, 'detected', detected, 'was', used,
                            'votes', jsonb_build_object('charging', votes_c, 'discharging', votes_d),
                            'flipped', jsonb_build_object('readings', n_read, 'agg', n_agg), 'decided', true);
end $$;

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
      update private.plant_alert_state set stale = true, stale_key = 'logger_stale:' || r.plant_id || ':' || r.last_dev
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
              when p_kind = 'string_dead' then 'solar'
              when p_kind in ('batt_hot', 'bank_drift') then 'inverters'
              else 'live' end;
  return jsonb_build_object(
    'title', title, 'body', body, 'at', ev, 'tab', tab, 'switch', private.email_switch(p_kind),
    'day', to_char(to_timestamp(ev) at time zone p_tz, 'YYYY-MM-DD'),
    'time', to_char(to_timestamp(ev) at time zone p_tz, 'HH24:MI'));
end $$;
