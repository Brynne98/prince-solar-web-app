-- ============================================================================
-- The battery pack is described in two places that can disagree.
--
-- public/app.jsx lets you edit battCapacity (26.5 kWh) and reserve (20%) from
-- the Settings tab; api_alerts_due hardcoded both as literals. Add a sixth
-- module, update Settings, and the dashboard follows while the phone alert
-- silently keeps assuming 26.5 -- under-reading the pack and firing too eagerly.
--
-- Same problem 0005 solved for the solar model, so use the same answer: put
-- them in app_config and read them through cfg(). That makes the backend agree
-- with itself. It does NOT reach the frontend, which is still localStorage-only
-- -- changing the reserve in Settings still does not move these. Making
-- Settings server-backed is the separate half of this.
--
-- coalesce'd to the current values so a missing row degrades to today's
-- behaviour rather than silently killing the alert (cfg() returns NULL for an
-- unknown key, and NULL hrs_left never fires).
-- ============================================================================

insert into public.app_config (key, value, note) values
  ('BATTERY_KWH',          26.5, 'usable pack energy, all banks (5 x 5.3 kWh)'),
  ('BATTERY_RESERVE_PCT',    20, 'floor where discharge stops; matches Settings')
on conflict (key) do update set value = excluded.value, note = excluded.note;

create or replace function public.api_alerts_due()
returns table (
  kind      text,
  event_key text,
  severity  text,
  title     text,
  body      text,
  value     double precision
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with
  now_s as (select extract(epoch from now())::bigint as t),
  loc as (
    select timezone('Africa/Johannesburg', now()) as ts,
           (timezone('Africa/Johannesburg', now()))::date as day,
           extract(hour from timezone('Africa/Johannesburg', now()))::int as hour
  ),
  hour_key as (
    select to_char(date_trunc('hour', timezone('Africa/Johannesburg', now())),
                   'YYYY-MM-DD"T"HH24') as k
  ),
  -- ── logger ──────────────────────────────────────────────────────────────
  -- api_health already treats 15 min of silence as stale.
  health as (
    select h.j->>'stale' = 'true' as stale,
           (h.j->>'ageSeconds')::double precision as age_s
      from (select public.api_health() as j) h
  ),
  -- ── banks / temp ────────────────────────────────────────────────────────
  bal as (
    select public.api_balance() as j
  ),
  -- ── overnight runtime ───────────────────────────────────────────────────
  -- Same numbers Live uses, now from app_config rather than literals so the
  -- two descriptions of the pack cannot drift. batt_w is stored
  -- +charging / −discharging. Skip the day — this is an evening question.
  batt_cfg as (
    select coalesce(public.cfg('BATTERY_KWH'), 26.5)       as pack_kwh,
           coalesce(public.cfg('BATTERY_RESERVE_PCT'), 20) as reserve_pct
  ),
  -- One row per minute of the last half hour, each carrying its own trailing
  -- 60-minute median draw. A median over an hour rides out a kettle; a mean
  -- would not.
  night_win as (
    select
      a.ts,
      a.soc,
      timezone('Africa/Johannesburg', to_timestamp(a.ts)) as lts,
      (select percentile_cont(0.5) within group
                (order by b.batt_w::double precision)
         from public.agg_minute b
        where b.ts > a.ts - 3600 and b.ts <= a.ts
          and b.batt_w is not null) as draw_w
      from public.agg_minute a, now_s
     where a.ts > now_s.t - 1800
  ),
  -- The same projection the old rule did once, now done per minute.
  night_calc as (
    select
      w.ts,
      -- night's date: after midnight, still the evening that started yesterday
      case when extract(hour from w.lts)::int < 6
           then w.lts::date - 1 else w.lts::date end as night_day,
      -- hours until 06:00. Evening (>=18) is tomorrow morning; pre-dawn is today.
      case
        when extract(hour from w.lts)::int >= 18 then
          extract(epoch from ((w.lts::date + 1) + time '06:00') - w.lts) / 3600.0
        when extract(hour from w.lts)::int < 6 then
          extract(epoch from (w.lts::date + time '06:00') - w.lts) / 3600.0
        else null
      end as hrs_to_sunrise,
      case when w.draw_w < -50
           then greatest(0.0, (coalesce(w.soc, 0) - c.reserve_pct) / 100.0 * c.pack_kwh)
                / (abs(w.draw_w) / 1000.0)
           else null end as hrs_left
      from night_win w, batt_cfg c
  ),
  -- Sustained: every night-minute in the window must agree. One minute back in
  -- the black resets it, hence bool_and. Reported hrs_left is the newest minute.
  overnight as (
    select
      (array_agg(night_day order by ts desc))[1] as night_day,
      (array_agg(hrs_left  order by ts desc))[1] as hrs_left,
      count(*) as n,
      bool_and(hrs_left is not null and hrs_left < hrs_to_sunrise) as sustained
      from night_calc
     where hrs_to_sunrise is not null
  ),
  -- ── grid presence, last 10 minutes ──────────────────────────────────────
  -- NULL present = firmware hasn't reported voltage; those minutes don't count.
  grid_min as (
    select r.ts, public.q_grid_present(r.ts) as present
      from (select distinct ts from public.readings, now_s
             where ts >= now_s.t - 1800) r
  ),
  -- relay state at the newest minute, to tell a real outage from a relay we opened
  relay as (
    select (select r.grid_relay_status from public.readings r
             where r.ts = (select max(ts) from public.readings)
               and r.grid_relay_status is not null limit 1) as status
  ),
  grid as (
    select
      (select present from grid_min order by ts desc limit 1) as latest,
      (select count(*) from grid_min, now_s
        where ts >= now_s.t - 180 and present is false) as false_3m,
      (select count(*) from grid_min, now_s
        where ts >= now_s.t - 180 and present is true) as true_3m,
      (select count(*) from grid_min, now_s
        where ts >= now_s.t - 1800 and present is false) as false_30m,
      (select count(*) from grid_min, now_s
        where ts >= now_s.t - 120 and present is false) as false_2m
  ),
  -- ── strings ─────────────────────────────────────────────────────────────
  -- Same test the Solar tab uses for its "check" badge (v < 1.5 && p < 5),
  -- not the "idle" badge (p < 5 alone). Idle is normal in shade. Dead is
  -- no voltage while a sibling on that inverter is still producing.
  str_latest as (select max(ts) as ts from public.strings),
  dead_held as (
    select s.sn, s.no
      from public.strings s, loc, now_s
     where loc.hour between 11 and 14
       and s.ts >= now_s.t - 900
       and coalesce(s.volt_v, 0) < 1.5
       and coalesce(s.power_w, 0) < 5
       and exists (
         select 1 from public.strings o
          where o.ts = s.ts and o.sn = s.sn and o.no is distinct from s.no
            and coalesce(o.power_w, 0) > 200
       )
     group by s.sn, s.no
    having count(*) >= 12
       and exists (
         select 1 from public.strings cur, str_latest
          where cur.ts = str_latest.ts
            and cur.sn = s.sn and cur.no = s.no
            and coalesce(cur.volt_v, 0) < 1.5
            and coalesce(cur.power_w, 0) < 5
       )
  ),
  dead as (
    select
      count(*)::int as n,
      string_agg(
        'string ' || d.no::text || coalesce(' on ' || nullif(m.alias, ''), ''),
        ', ' order by m.alias, d.no
      ) as which
      from dead_held d
      left join private.meta m on m.sn = d.sn
  )
  -- logger stale: re-notify hourly while it stays down
  select 'logger_stale',
         'logger_stale:' || (select k from hour_key),
         'urgent',
         'Solar logger stopped',
         'No data for ' || greatest(1, round(age_s / 60.0))::int || ' minutes',
         age_s
    from health where stale

  union all
  select 'bank_drift',
         'bank_drift:' || (select k from hour_key),
         'urgent',
         'Battery banks drifting',
         coalesce(round((j->>'socSpread')::numeric, 0)::text, '?') || '% apart for 10 minutes',
         (j->>'socSpread')::double precision
    from bal where j->>'status' = 'drifting'

  union all
  select 'batt_hot',
         'batt_hot:' || (select day from loc)::text,
         'urgent',
         'Battery is hot · ' || round((j->>'tempC')::numeric, 0)::text || '°C',
         '',
         (j->>'tempC')::double precision
    from bal where (j->>'tempHot')::boolean is true

  union all
  select 'soc_overnight',
         'soc_overnight:' || night_day::text,
         'urgent',
         'Battery won''t last the night',
         floor(hrs_left)::int || 'h '
            || lpad(round((hrs_left - floor(hrs_left)) * 60)::int::text, 2, '0')
            || 'm left at tonight''s draw',
         hrs_left
    from overnight
   -- n >= 25 tolerates a few dropped logger minutes rather than demanding a
   -- clean 30. Below that we do not have the window, so we do not fire.
   where sustained
     and n >= 25

  union all
  -- Both cases still notify — the wording carries the confidence.
  --
  -- relay CLOSED with no volts is unambiguous: connected, and no mains. relay OPEN
  -- with no volts is the case we cannot read yet, because we have never observed what
  -- this firmware reports while the relay is open. If one of those arrives and the
  -- power was actually on, voltage tracks the relay and these rules need gating for
  -- real. See FEATURES.md, "Open question — grid presence".
  select 'grid_down',
         'grid_down:' || (select k from hour_key),
         'urgent',
         case when (select status from relay) = '1' then 'Grid is off'
              else 'Grid may be off' end,
         case when (select status from relay) = '1'
              then 'No mains voltage while still connected'
              else 'No voltage, but the inverter has also opened the relay — unconfirmed' end,
         null
    from grid
   where latest is false and false_3m >= 3 and true_3m = 0

  union all
  select 'grid_back',
         'grid_back:' || (select k from hour_key),
         'urgent',
         'Grid is back',
         '',
         null
    from grid
   where latest is true
     and false_2m = 0
     and false_30m >= 3

  union all
  select 'string_dead',
         'string_dead:' || (select day from loc)::text,
         'digest',
         case when n = 1 then 'A solar string looks dead'
              else n::text || ' solar strings look dead' end,
         which || ' — no voltage, sibling still producing',
         n::double precision
    from dead
   where n > 0
$$;

revoke all on function public.api_alerts_due() from public, anon, authenticated;
grant execute on function public.api_alerts_due() to service_role;

comment on function public.api_alerts_due is
  'Alerts due for a phone push. Pure read; the todo app stamps what it actually sent.';
