CREATE OR REPLACE FUNCTION public.email_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  now_s bigint := extract(epoch from now())::bigint;
  b plants.brand_state;
  tried int;
  failing int;
  t_all int := 0;
  f_all int := 0;
  down boolean;
  r record;
  n_stale int := 0;
  n_rep int := 0;
begin
  -- Each brand's cloud on its own (R17): one brand's outage never mutes another's alerts. A
  -- login counts when poll tried it in the last 10 minutes; it is failing when its last try
  -- was the brand's fault and nothing good came for 10 min. Down: over half failing, and at
  -- least 3 of them, or all of them when fewer than 3 were tried (0119). Back once not down
  -- for 15 min (0151). Outage ids come from one sequence, so mail keys never meet across brands.
  for b in select * from plants.brand_state order by brand for update loop
    select count(*) filter (where a.last_try_at > now() - interval '10 minutes'),
           count(*) filter (where a.last_try_at > now() - interval '3 minutes' and a.last_try = 'vendor'
                              and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes')
      into tried, failing
      from plants.logins a where a.status = 'ok' and a.brand = b.brand;
    t_all := t_all + tried; f_all := f_all + failing;
    down := failing >= least(3, tried) and failing > 0 and failing * 2 > tried;

    if down and not b.down then
      b.down := true; b.outage_id := nextval('plants.outage_id_seq'); b.clear_since := null;
      b.down_since := (select extract(epoch from min(coalesce(a.last_ok_at, a.linked_at)))::bigint
                         from plants.logins a
                        where a.status = 'ok' and a.brand = b.brand and a.last_try = 'vendor'
                          and a.last_try_at > now() - interval '3 minutes'
                          and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes');
    elsif down then
      b.clear_since := null;
    elsif b.down then
      b.clear_since := coalesce(b.clear_since, now());
      if b.clear_since <= now() - interval '15 minutes' then
        -- Back: everyone told it was down hears it is back.
        insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
        select q.user_id, q.plant_id, 'sunsynk_back', 'sunsynk_back:' || b.outage_id, q.key,
               jsonb_build_object('since', b.down_since, 'at', extract(epoch from b.clear_since)::bigint), 0
          from public.email_queue q
         where q.key = 'sunsynk_down:' || b.outage_id
        on conflict do nothing;
        b.down := false; b.up_at := now(); b.clear_since := null;
      end if;
    end if;
    if b.down then
      -- Users on a failing login; one email each, about their first plant on it.
      -- Run every minute of the outage, so a login that fails later is told too.
      insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
      select distinct on (pu.user_id) pu.user_id, pu.plant_id, 'sunsynk_down', 'sunsynk_down:' || b.outage_id,
             jsonb_build_object('since', b.down_since), 0
        from plants.logins a join plants.user_plants pu on pu.account_id = a.id
       where a.status = 'ok' and a.brand = b.brand and a.last_try = 'vendor' and a.last_try_at > now() - interval '3 minutes'
         and coalesce(a.last_ok_at, a.linked_at) < now() - interval '10 minutes'
         and private.plant_live(pu.user_id, pu.plant_id)                          -- 0256
       order by pu.user_id, pu.linked_at
      on conflict do nothing;
    end if;
    update plants.brand_state set down = b.down, outage_id = b.outage_id, down_since = b.down_since,
           up_at = b.up_at, clear_since = b.clear_since
     where brand = b.brand;
  end loop;

  -- No readings: 30 min since the brand's newest reading for the plant, while poll
  -- still tries a login on it (ours not running is not the inverter going quiet),
  -- and not during an outage of the plant's brand (that has its own email) nor in the
  -- 15 min after one, while readings that the outage held up come back. A plant started
  -- again gets 30 min from the start, as a new link does (0174).
  begin
    for r in
      select s.plant_id, s.last_dev from private.plant_alert_state s
       where not s.stale and s.last_dev < now_s - 1800 and not coalesce(s.started_at between now_s - 1800 and now_s, false)   -- 0174
         and exists (select 1 from plants.brand_state bs
                      where bs.brand = plants.brand_of(s.plant_id) and not bs.down and (bs.up_at is null or bs.up_at < now() - interval '15 minutes'))
         and exists (select 1 from plants.user_plants pu join plants.logins a on a.id = pu.account_id
                      where pu.plant_id = s.plant_id and a.status = 'ok' and a.last_try in ('ok', 'vendor')
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
         and exists (select 1 from plants.brand_state bs
                      where bs.brand = plants.brand_of(i.plant_id) and not bs.down and (bs.up_at is null or bs.up_at < now() - interval '15 minutes'))
         and exists (select 1 from plants.user_plants pu join plants.logins a on a.id = pu.account_id
                      where pu.plant_id = i.plant_id and a.status = 'ok' and a.last_try in ('ok', 'vendor')
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
  end;

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

  return jsonb_build_object('down', (select coalesce(jsonb_agg(x.brand order by x.brand), '[]') from plants.brand_state x where x.down),
                            'tried', t_all, 'failing', f_all,
                            'stale', n_stale, 'reports', n_rep);
end $function$;
