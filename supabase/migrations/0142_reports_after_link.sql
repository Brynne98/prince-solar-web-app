-- SOLAR-305: weekly, monthly and yearly reports skip a period that began before the
-- plant was linked (replaces SOLAR-273's "every plant linked before the report goes").
-- email_sweep's body is 0137's with only the report step changed to read reports_due.

-- The reports due at p_now: weekly on Monday, monthly on the 1st, yearly on 1 January,
-- from 07:00 in the plant's time zone. A plant linked after the first day of the period
-- a report covers gets none for that period: its numbers would come from the 60-day
-- import, not from its time here (SOLAR-305). Its first report covers its first full
-- week, month or year. p_now is an argument so a test can pick the day.
create or replace function private.reports_due(p_now timestamptz)
returns table (user_id uuid, plant_id bigint, d date, period text)
language sql stable set search_path = public, private, pg_temp as $$
  with loc as (
    select pu.user_id, pu.plant_id, timezone(public.plant_tz(pu.plant_id), p_now) as t,
           timezone(public.plant_tz(pu.plant_id), pu.linked_at)::date as linked_on
      from public.plant_users pu
  )
  select l.user_id, l.plant_id, l.t::date, p.period
    from loc l, lateral (values ('week'), ('month'), ('year')) p(period)
   where extract(hour from l.t) >= 7
     and case p.period when 'week'  then extract(isodow from l.t) = 1
                       when 'month' then extract(day from l.t) = 1
                       else extract(day from l.t) = 1 and extract(month from l.t) = 1 end
     and l.linked_on <= case p.period when 'week'  then l.t::date - 7
                                      when 'month' then (date_trunc('month', l.t) - interval '1 month')::date
                                      else (date_trunc('year', l.t) - interval '1 year')::date end
$$;
revoke all on function private.reports_due(timestamptz) from public, anon, authenticated;

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
                            'stale', n_stale, 'reminders', n_rem, 'reports', n_rep);
end $$;
