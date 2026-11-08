-- ============================================================================
-- 0167 — One start time for a grid outage, everywhere (SOLAR-430).
--
-- 8 Nov, plant 538820: the grid was off 14:51 to 19:24 (SunSynk history 0 Hz from
-- 14:51:51, our readings back on at 19:24). Our readings had a hole 13:53-14:55 (dead
-- login). The bell said "14:55 to 19:24, 4h 29m" (notice queued before 0164), the Grid
-- tab "Grid off 4h 35m" (whole 5-minute blocks), Equipment "Off 4h 29m today" (our
-- readings only).
--
--   grid_minutes        minutes we have no reading for come from SunSynk's history:
--                       grid frequency 40 Hz or over is on. Plants without a grid skip it.
--                       grid_off, api_grid_today and everything below read this.
--   grid_off_began      the first off minute of the run holding p_seen, when the minute
--                       before it is known on (3 min slack for history spacing); else null.
--   grid_off_start      0164's answer, now from grid_off_began. Same shape: {since} or
--                       {since, from} when the start is not known yet.
--   grid_notice_data    a grid_down / grid_back row's data with since worked out again
--                       from the data, so notices already sent show the start too
--                       (Brynne, 8 Nov: recompute old notices). Emails and pop-ups that
--                       went out keep what they said.
--   api_alerts          0166's body; reads the row data through grid_notice_data.
--   api_grid_off_recent 0122's body; startedAt through grid_off_began.
--   api_grid_today      0159's body plus p_date (a past day), so the Grid tab's and
--                       Equipment's "Grid off" counts minutes, not 5-minute blocks; asOf
--                       lets a page keep counting while the grid stays off.
-- No table changes.
-- ============================================================================

create or replace function private.grid_minutes(p_plant bigint, p_from bigint, p_to bigint)
returns table (ts bigint, present boolean)
language sql
stable
set search_path = public, pg_temp
as $$
  with voters as (
    select r.ts, r.grid_volt_v, r.device_time
      from public.readings r
     where r.plant_id = p_plant
       and r.ts >= p_from and r.ts < p_to
       and r.grid_volt_v is not null
       and (r.grid_volt_v <> 0 or r.device_time is not null)
  ),
  newest as (
    select v.ts, max(v.device_time) as dt from voters v group by v.ts
  ),
  ours as (
    select v.ts, bool_or(v.grid_volt_v > 100) as present
      from voters v join newest n on n.ts = v.ts
     where v.device_time is not distinct from n.dt
     group by v.ts
  ),
  -- 0167: SunSynk's history for the minutes we have no reading for
  hist as (
    select (h.ts / 60) * 60 as ts, bool_or(h.grid_fac_hz >= 40) as present
      from public.inverter_history h
     where h.plant_id = p_plant
       and h.ts >= p_from and h.ts < p_to
       and h.grid_fac_hz is not null
       and coalesce((select c.has_grid from public.plant_config c where c.plant_id = p_plant), true)
     group by 1
  )
  select o.ts, o.present from ours o
  union all
  select h.ts, h.present from hist h where not exists (select 1 from ours o where o.ts = h.ts)
$$;
revoke all on function private.grid_minutes(bigint, bigint, bigint) from public, anon, authenticated;

-- When the off run holding p_seen began, or null when the minutes before it are not known.
create or replace function private.grid_off_began(p_plant bigint, p_seen bigint)
returns bigint language sql stable security definer set search_path = '' as $$
  with m as (select g.ts, g.present from private.grid_minutes(p_plant, p_seen - 43200, p_seen + 60) g),
  last_on as (select max(m.ts) ts from m where m.present and m.ts < p_seen)
  select min(m.ts) from m, last_on
   where not m.present and m.ts > last_on.ts and m.ts <= p_seen
  having min(m.ts) - max(last_on.ts) <= 180
$$;
revoke all on function private.grid_off_began(bigint, bigint) from public, anon, authenticated;

-- When the grid went off, for an off run first seen at p_seen. {since} or {since, from}.
create or replace function private.grid_off_start(p_plant bigint, p_seen bigint)
returns jsonb language sql stable security definer set search_path = '' as $$
  with b as (select private.grid_off_began(p_plant, p_seen) ts),
  last_on as (select max(g.ts) ts from private.grid_minutes(p_plant, p_seen - 43200, p_seen) g where g.present)
  select case
    when b.ts is not null then jsonb_build_object('since', b.ts)
    when last_on.ts is null then jsonb_build_object('since', p_seen)
    else jsonb_build_object('since', p_seen, 'from', last_on.ts) end
    from b, last_on
$$;
revoke all on function private.grid_off_start(bigint, bigint) from public, anon, authenticated;

-- A queued row's data as the app shows it: a grid notice's start worked out from the data.
create or replace function private.grid_notice_data(p_plant bigint, p_kind text, d jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when p_kind in ('grid_down', 'grid_back') and p_plant is not null and d ? 'since'
    then coalesce((select (d - 'from') || jsonb_build_object('since', b.ts)
                     from (select private.grid_off_began(p_plant, (d->>'since')::bigint) ts) b
                    where b.ts is not null), d)
    else d end
$$;
revoke all on function private.grid_notice_data(bigint, text, jsonb) from public, anon, authenticated;

create or replace function public.api_alerts(p_from timestamptz default null, p_switch text default null,
                                             p_unread boolean default false, p_before bigint default null,
                                             p_before_ts timestamptz default null, p_limit int default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  with a as (
    -- every alert the user can still see: plants still linked
    select q.id, q.kind, q.key, q.plant_id, pu.plant_name, q.read_at, q.created_at, q.data
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid() and private.is_alert(q.kind)),
  e as (
    select s.* from a s
     where (p_from is null or s.created_at >= p_from)
       and (p_switch is null or private.alert_group(s.kind) = p_switch)
       and (p_before is null or (s.created_at, s.id) < (p_before_ts, p_before))
       and (not p_unread or s.read_at is null)
     order by s.created_at desc, s.id desc
     limit greatest(1, least(p_limit, 200)) + 1),
  shown as (select * from e order by created_at desc, id desc limit greatest(1, least(p_limit, 200))),
  -- when each "back" kind was first sent, by anyone; Reconnected exists from 0158 on
  firsts as (select f.kind, min(f.at) at from (
               select q.kind, q.created_at at from public.email_queue q
                where q.kind in (select private.alert_back_kind(k.kind) from shown k)
               union all select 'relinked', timestamptz '2026-11-07 00:00+02') f
              group by f.kind)
  select jsonb_build_object(
    'more', (select count(*) from e) > greatest(1, least(p_limit, 200)),
    'unread', (select count(*) from a where read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'ts', s.created_at, 'kind', s.kind, 'plant', s.plant_id, 'plantName', s.plant_name,
        'read', s.read_at is not null,
        'ids', jsonb_build_array(s.id),
        'open', coalesce(private.is_alert(private.alert_back_kind(s.kind)), false)
                and not exists (select 1 from public.email_queue b where b.user_id = auth.uid() and b.pair_key = s.key)
                and coalesce(s.created_at >= (select f.at from firsts f where f.kind = private.alert_back_kind(s.kind)), false)
                and not exists (select 1 from public.email_queue l where l.user_id = auth.uid() and l.plant_id = s.plant_id
                                  and l.kind = s.kind and l.created_at > s.created_at))
        || t
        order by s.created_at desc, s.id desc) from shown s
        cross join lateral (select private.alert_text(s.kind, private.grid_notice_data(s.plant_id, s.kind, s.data),   -- 0167
                                                      s.created_at, public.plant_tz(s.plant_id)) t) x),
      '[]'::jsonb));
$$;

create or replace function public.api_grid_off_recent(p_plant bigint default null)
returns jsonb
language sql stable security definer set search_path = public, pg_temp
as $$
  select jsonb_build_object('startedAt', coalesce(to_timestamp(private.grid_off_began(g.plant_id,       -- 0167
                                           extract(epoch from g.started_at)::bigint)), g.started_at),
                            'endedAt', g.ended_at)
    from public.grid_off g
   where g.plant_id = public.my_plant(p_plant) and g.ended_at > now() - interval '24 hours'
   order by g.ended_at desc
   limit 1
$$;

-- p_date: a past day in the plant's time zone; null is today, up to now.
drop function if exists public.api_grid_today(bigint);
create or replace function public.api_grid_today(p_plant bigint default null, p_date date default null)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with p as (select public.my_plant(p_plant) as id),
  z as (
    select p.id, coalesce((select c.timezone from public.plant_config c where c.plant_id = p.id),
                          'Africa/Johannesburg') as tz
      from p
  ),
  lo as (
    select z.id,
           extract(epoch from coalesce(p_date, (now() at time zone z.tz)::date)::timestamp at time zone z.tz)::bigint as t0,
           least(extract(epoch from (coalesce(p_date, (now() at time zone z.tz)::date) + 1)::timestamp at time zone z.tz)::bigint,
                 extract(epoch from now())::bigint + 60) as t1
      from z
  ),
  m as (
    select g.ts, g.present
      from lo, private.grid_minutes(lo.id, lo.t0, lo.t1) g
  ),
  v as (
    select ((r.ts - lo.t0) / 300)::int as b,
           avg(r.grid_volt_v) filter (where r.grid_volt_v > 100) as volt
      from lo join public.readings r on r.plant_id = lo.id and r.ts >= lo.t0 and r.ts < lo.t1
     group by 1
  ),
  o as (
    select ((m.ts - lo.t0) / 300)::int as b, bool_or(not m.present) as off
      from m, lo
     group by 1
  )
  select jsonb_build_object(
    'buckets', coalesce((
      select jsonb_agg(jsonb_build_object(
               'i', coalesce(v.b, o.b),
               'v', round(v.volt::numeric, 1),
               'off', coalesce(o.off, false))
             order by coalesce(v.b, o.b))
        from v full join o on o.b = v.b), '[]'::jsonb),
    'offMinutes', (select count(*) from m where not m.present),
    'asOf', extract(epoch from now())::bigint                                    -- 0167
  )
$$;
revoke all on function public.api_grid_today(bigint, date) from public, anon;
grant execute on function public.api_grid_today(bigint, date) to authenticated, service_role;
