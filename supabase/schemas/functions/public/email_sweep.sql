CREATE OR REPLACE FUNCTION public.email_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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
       and private.plant_live(pu.user_id, pu.plant_id)                          -- 0256
     order by pu.user_id, pu.linked_at
    on conflict do nothing;
  end if;
  update private.email_system_state set sunsynk_down = sys.sunsynk_down, outage_id = sys.outage_id, down_since = sys.down_since,
         up_at = sys.up_at, clear_since = sys.clear_since
   where id = 1;

  -- No readings: 30 min since SunSynk's newest reading for the plant, while poll
  -- still tries a login on it (ours not running is not the inverter going quiet),
  -- and not during a SunSynk outage (that has its own email) nor in the 15 min
  -- after one, while readings that the outage held up come back. A plant started
  -- again gets 30 min from the start, as a new link does (0174).
  if not sys.sunsynk_down and (sys.up_at is null or sys.up_at < now() - interval '15 minutes') then
    for r in
      select s.plant_id, s.last_dev from private.plant_alert_state s
       where not s.stale and s.last_dev < now_s - 1800 and not coalesce(s.started_at between now_s - 1800 and now_s, false)   -- 0174
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
       where not i.stale and i.last_dev < now_s - 1800 and not coalesce(s.started_at between now_s - 1800 and now_s, false)   -- 0174
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
end $function$;
