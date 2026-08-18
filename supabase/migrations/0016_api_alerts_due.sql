-- ============================================================================
-- api_alerts_due() — what is worth telling a phone about right now.
--
-- Detection lives here, next to the readings it reads. prince-todo-app's
-- solar-alerts function only words nothing extra: it sends these rows and
-- stamps solar_alerts_sent so a repeat of the same event_key is a no-op.
--
-- Granted to service_role only. The todo app calls this with this project's
-- secret key; authenticated dashboard sessions never see it.
--
-- event_key encodes the occurrence, not a boolean state. Hourly keys re-notify
-- a still-active urgent alert after an hour; daily keys fire once per local
-- day. Grid uses voltage (q_grid_present), not grid_w — power is zero on a
-- quiet solar afternoon too.
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
  select 'grid_down',
         'grid_down:' || (select k from hour_key),
         'urgent',
         'Grid is off',
         '',
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
