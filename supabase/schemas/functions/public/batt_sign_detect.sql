CREATE OR REPLACE FUNCTION public.batt_sign_detect(p_plant bigint, p_default text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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
  -- the nightly rollup is working: decide on a later poll (SOLAR-651). First, before
  -- the vote reads readings, so this never waits for the key holding a table lock.
  if not pg_try_advisory_xact_lock_shared(8, 651) then
    return jsonb_build_object('plant', p_plant, 'skipped', 'rollup busy');
  end if;
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
    -- raw days the rollup already started hold 5-minute rows of the old sign: redo this plant
    update private.rollup_progress
       set redo = array(select distinct unnest(redo || p_plant))
     where parent = 'readings' and next_ts > lo and since < hi;
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
end $function$;
