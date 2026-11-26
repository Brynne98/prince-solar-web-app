CREATE OR REPLACE FUNCTION public.email_poll_step(p_ts bigint, p_outcomes jsonb, p_plants bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  todo bigint[];
  r record;
  clr bigint;
  failed jsonb := '[]'::jsonb;
begin
  perform public.login_outcomes(p_outcomes);   -- the reader records outcomes itself now (R18)

  -- Plants with config (purged ones have none) not already stepped for this minute.
  -- The rows stay locked to the end, so a link kick polling the same account in the
  -- same minute waits here and then finds them stepped: strings are counted once.
  insert into private.plant_alert_state (plant_id)
  select c.plant_id from plants.settings c where c.plant_id = any (coalesce(p_plants, '{}')) order by 1
  on conflict do nothing;
  select coalesce(array_agg(x.plant_id), '{}') into todo
    from (select s.plant_id from private.plant_alert_state s
           where s.plant_id = any (coalesce(p_plants, '{}')) and (s.stepped_ts is null or s.stepped_ts < p_ts)
           order by s.plant_id for update) x;

  -- Strings, all plants at once: a string with voltage is alive; one under 1.5 V and
  -- 5 W while another string on the plant makes over 200 W counts a dead sample, but
  -- only once the string itself has made over 200 W (an input with no panels never
  -- has; SOLAR-188). A string on another inverter counts only when both inverters
  -- reported in the last 10 min (poll carries an inverter's strings for 5 runs), so an
  -- inverter's only used string can stop and be seen (0231, SOLAR-613). A dead string
  -- stays dead until it has had voltage for 15 min with no dead sample (clear_at, 0151).
  insert into private.string_alert_state as st (plant_id, sn, no, last_alive, dead_n, made_power)
  with fresh as (
    select x.plant_id, x.sn
      from public.readings x join plants.settings c on c.plant_id = x.plant_id
     where x.plant_id = any (todo) and x.ts = p_ts and x.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
     group by x.plant_id, x.sn
    having max(extract(epoch from (x.device_time::timestamp at time zone plants.tz(c.plant_id)))::bigint) >= p_ts - 600
  )
  select x.plant_id, x.sn, x.no, case when x.alive then p_ts end, 0, x.made
    from (select s.plant_id, s.sn, s.no, coalesce(s.volt_v, 0) >= 1.5 as alive,
                 coalesce(s.power_w, 0) > 200 as made,
                 coalesce(s.volt_v, 0) < 1.5 and coalesce(s.power_w, 0) < 5
                   and exists (select 1 from public.strings o where o.plant_id = s.plant_id and o.ts = p_ts
                                  and (o.sn, o.no) <> (s.sn, s.no) and coalesce(o.power_w, 0) > 200
                                  and (o.sn = s.sn
                                       or (exists (select 1 from fresh f where f.plant_id = s.plant_id and f.sn = s.sn)
                                           and exists (select 1 from fresh f where f.plant_id = o.plant_id and f.sn = o.sn)))) as dead_in_sun
            from public.strings s
           where s.plant_id = any (todo) and s.ts = p_ts) x
   where x.alive or x.dead_in_sun
  on conflict (plant_id, sn, no) do update set
    last_alive = coalesce(excluded.last_alive, st.last_alive),
    made_power = st.made_power or excluded.made_power,
    dead_n     = case when excluded.last_alive is not null or not st.made_power then 0
                      when st.dead then st.dead_n else st.dead_n + 1 end,
    clear_at   = case when st.dead and excluded.last_alive is not null then coalesce(st.clear_at, excluded.last_alive) end;
  -- Strings dead in the sun for 12 samples: one email each. When every string that has
  -- made power on an inverter stops in the same minute, that is one email for the
  -- inverter ("Strings 1 and 2"), kept on its lowest string; the others are marked with
  -- group_no and come back without an email of their own (0231).
  for r in
    with due as (
      select a.plant_id, a.sn, a.no, coalesce(a.last_alive + 60, p_ts - 900) as since
        from private.string_alert_state a
       where a.plant_id = any (todo) and not a.dead and a.dead_n >= 12
    ), inv as (
      select d.plant_id, d.sn, min(d.no) as first_no, count(*) as n,
             array_agg(d.no order by d.no) as nos
        from due d group by d.plant_id, d.sn
    ), whole as (
      select i.* from inv i
       where i.n >= 2
         and i.n = (select count(*) from private.string_alert_state a
                     where a.plant_id = i.plant_id and a.sn = i.sn and a.made_power and not a.dead)
    )
    select d.plant_id, d.sn, d.no, d.since, w.first_no, w.nos,
           coalesce(nullif(m.alias, ''), 'Inverter ' || d.sn) as inverter
      from due d left join whole w on w.plant_id = d.plant_id and w.sn = d.sn
      left join plants.meta_info m on m.sn = d.sn
     order by d.plant_id, m.ord nulls last, d.sn, d.no
  loop
    if r.first_no is null or r.first_no = r.no then
      -- strings left pointing here by an older email are free of it now
      update private.string_alert_state set group_no = null
       where plant_id = r.plant_id and sn = r.sn and group_no = r.no and no <> r.no and not dead;
    end if;
    update private.string_alert_state set dead = true, dead_since = r.since, sent_at = now(), n = 1, clear_at = null,
                                          group_no = r.first_no
     where plant_id = r.plant_id and sn = r.sn and no = r.no;
    if r.first_no is null or r.first_no = r.no then
      perform private.email_enqueue_plant(r.plant_id, 'string_dead',
        'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.since || ':1',
        jsonb_build_object('string', private.string_names(coalesce(r.nos, array[r.no])), 'inverter', r.inverter, 'since', r.since));
    end if;
  end loop;
  -- Dead strings with voltage for 15 min: one "back" each. It goes on a minute with
  -- voltage, so one stray sample before nightfall cannot send it overnight. A string
  -- that went in another string's email comes back quietly; the one that held the
  -- email waits for all of them, then names every one (0231).
  for r in
    select a.plant_id, a.sn, a.no, a.dead_since, a.clear_at, a.group_no,
           (select array_agg(g.no order by g.no) from private.string_alert_state g
             where g.plant_id = a.plant_id and g.sn = a.sn and g.group_no = a.no) as nos,
           coalesce(nullif(m.alias, ''), 'Inverter ' || a.sn) as inverter
      from private.string_alert_state a left join plants.meta_info m on m.sn = a.sn
     where a.plant_id = any (todo) and a.dead and p_ts - a.clear_at >= 900 and a.last_alive = p_ts
       -- an email's holder waits until every string in it is back (0231)
       and not exists (select 1 from private.string_alert_state g
                        where g.plant_id = a.plant_id and g.sn = a.sn and g.group_no = a.no and g.no <> a.no and g.dead
                          and not (p_ts - g.clear_at >= 900 and g.last_alive = p_ts))
     order by a.plant_id, m.ord nulls last, a.sn, a.no
  loop
    -- a string that went in another's email keeps group_no while that one is still
    -- off, so its "back" names this string too
    update private.string_alert_state a
       set dead = false, dead_n = 0, clear_at = null,
           group_no = case when a.group_no <> a.no and exists (
                             select 1 from private.string_alert_state h
                              where h.plant_id = a.plant_id and h.sn = a.sn and h.no = a.group_no and h.dead)
                           then a.group_no end
     where a.plant_id = r.plant_id and a.sn = r.sn and a.no = r.no;
    if r.group_no is null or r.group_no = r.no then
      update private.string_alert_state set group_no = null
       where plant_id = r.plant_id and sn = r.sn and group_no = r.no and not dead;
      perform private.email_enqueue_plant(r.plant_id, 'string_back',
        'string_back:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.dead_since,
        jsonb_build_object('string', private.string_names(coalesce(r.nos, array[r.no])), 'inverter', r.inverter,
                           'since', r.dead_since, 'at', r.clear_at),
        'string_dead:' || r.plant_id || ':' || r.sn || ':' || r.no || ':' || r.dead_since || ':1');
    end if;
  end loop;

  -- Each inverter's own newest reading (0119). One that was quiet gets its Readings
  -- back once it has reported for 15 min with no gap over 10 min (0151).
  for r in
    with d as (
      select x.plant_id, x.sn,
             max(extract(epoch from (x.device_time::timestamp at time zone plants.tz(c.plant_id)))::bigint) as dev
        from public.readings x join plants.settings c on c.plant_id = x.plant_id
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
                             'inverter', coalesce((select nullif(m.alias, '') from plants.meta_info m where m.sn = r.sn), 'Inverter ' || r.sn)),
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
                             else coalesce(bool_or(public.grid_live(rd.grid_volt_v)) filter (
                                    where rd.grid_volt_v is not null and rd.device_time is not distinct from n.dt), false) end,
             'dev', max(case when rd.device_time ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
                             then extract(epoch from (rd.device_time::timestamp at time zone plants.tz(c.plant_id)))::bigint end),
             'temp', max(rd.batt_temp_c) filter (where rd.batt_temp_c > 0 and rd.batt_temp_c < 80),
             'spread', case when count(distinct rd.sn) filter (where rd.batt_soc between 1 and 100) >= 2
                            then max(rd.batt_soc) filter (where rd.batt_soc between 1 and 100)
                               - min(rd.batt_soc) filter (where rd.batt_soc between 1 and 100) end,
             'has_batt', coalesce(c.has_battery, true),
             'shared', coalesce(c.battery_banks = 'shared', false)) as f
      from plants.settings c
      join rd on rd.plant_id = c.plant_id
      left join newest n on n.plant_id = c.plant_id
     where c.plant_id = any (todo)
     group by c.plant_id, c.has_battery, c.battery_banks
  loop
    begin
      perform private.email_plant_apply(r.plant_id, p_ts, r.f);
    exception when others then
      failed := failed || jsonb_build_object('plant', r.plant_id, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('plants', coalesce(array_length(todo, 1), 0), 'failed', failed);
end $function$;
