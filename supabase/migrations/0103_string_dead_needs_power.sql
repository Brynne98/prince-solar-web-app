-- SOLAR-188: no "panels stopped" email for an inverter input with no panels.
-- 0102's string_dead counted a dead sample whenever an input read under 1.5 V and
-- 5 W while a sibling made over 200 W. An unused input reads ~1 V, 0 W all day, so
-- it alerted every sunny morning (plant 538820, 26 Oct). Now an input counts dead
-- samples only after it has made over 200 W itself. Cost: an input already broken
-- when the plant is linked never alerts.

alter table private.string_alert_state
  add column if not exists made_power boolean not null default false;

-- From the readings we still hold: 31 days per minute, then 5-minute steps.
update private.string_alert_state a set made_power = true
 where exists (select 1 from public.strings s
                where s.plant_id = a.plant_id and s.sn = a.sn and s.no = a.no and s.power_w > 200)
    or exists (select 1 from public.strings_5m s
                where s.plant_id = a.plant_id and s.sn = a.sn and s.no = a.no and s.power_w_max > 200);
-- Inputs that never made power stop counting, and stop their daily reminder.
update private.string_alert_state set dead = false, dead_n = 0 where not made_power;

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
             'temp', round(max(rd.batt_temp_c) filter (where rd.batt_temp_c > 0 and rd.batt_temp_c < 80)),
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
