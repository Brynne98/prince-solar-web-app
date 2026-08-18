-- ============================================================================
-- Tell a confirmed outage apart from an unread one, without losing either alert.
--
-- 0016 fires grid_down whenever voltage reads ~0. That is only sound if voltage
-- means "mains present" — and we have never seen what this firmware reports while
-- the relay is OPEN, which on recent history happens in 1-3 stretches a fortnight.
-- If voltage simply tracks the relay, every self-powered afternoon looks like a
-- blackout.
--
-- Both cases still push, deliberately: the first one that arrives is the experiment
-- that settles the question. Only the wording differs, so the notification itself
-- says whether to trust it.
-- ============================================================================

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
  -- Same numbers Live uses: 26.5 kWh pack, 20% reserve. batt_w is stored
  -- +charging / −discharging. Skip the day — this is an evening question.
  latest as (
    select soc, batt_w, ts from public.agg_minute order by ts desc limit 1
  ),
  night as (
    select
      l.soc,
      l.batt_w,
      loc.hour,
      loc.day,
      -- night's date: after midnight, still the evening that started yesterday
      case when loc.hour < 6 then loc.day - 1 else loc.day end as night_day,
      greatest(0.0, (coalesce(l.soc, 0) - 20) / 100.0 * 26.5) as avail_kwh,
      -- hours until 06:00. Evening (>=18) is tomorrow morning; pre-dawn is today.
      case
        when loc.hour >= 18 then
          extract(epoch from ((loc.day + 1) + time '06:00') - loc.ts) / 3600.0
        when loc.hour < 6 then
          extract(epoch from (loc.day + time '06:00') - loc.ts) / 3600.0
        else null
      end as hrs_to_sunrise
    from latest l, loc
  ),
  overnight as (
    select
      n.*,
      case when n.batt_w is not null and n.batt_w < -50
           then n.avail_kwh / (abs(n.batt_w) / 1000.0)
           else null end as hrs_left
    from night n
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
  -- ── strings at the latest sample ────────────────────────────────────────
  str_latest as (select max(ts) as ts from public.strings),
  dead as (
    select s.sn, s.no, s.power_w
      from public.strings s, str_latest, loc
     where s.ts = str_latest.ts
       and loc.hour between 10 and 14
       and coalesce(s.power_w, 0) < 5
       and exists (
         select 1 from public.strings o
          where o.ts = s.ts and o.sn = s.sn and o.no is distinct from s.no
            and coalesce(o.power_w, 0) > 50
       )
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
            || 'm left at this draw',
         hrs_left
    from overnight
   where hrs_left is not null
     and hrs_to_sunrise is not null
     and hrs_left < hrs_to_sunrise

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
         'string_dead:' || sn || ':' || no || ':' || (select day from loc)::text,
         'digest',
         'A solar string looks dead',
         'String ' || no || ' idle, sibling still producing',
         power_w
    from dead
$$;

revoke all on function public.api_alerts_due() from public, anon, authenticated;
grant execute on function public.api_alerts_due() to service_role;

comment on function public.api_alerts_due is
  'Alerts due for a phone push. Pure read; the todo app stamps what it actually sent.';
