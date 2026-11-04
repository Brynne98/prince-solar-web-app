-- ============================================================================
-- 0152 — Every alert, for the full Notifications page (SOLAR-327).
--
-- The bell's quick list (api_notifications, 0124) shows the last 30 days as sent:
-- a "down" and its "back" are two rows. This page shows one row per alert: when it
-- started and when it went back to normal. A "back" is the email_queue row whose
-- pair_key is its "down"'s key (0102; SOLAR-320's 0151 adds backs for battery, uneven
-- charging and strings the same way). Reads alerts as stored; sends nothing.
--
--   api_alerts(from, switch, unread, before, before_ts, limit)
--     from     only alerts that started at or after it; null = all time
--     switch   grid, battery, panels, readings or sunsynk (email_switch); null = all
--     unread   only alerts with a row not yet read
--     before, before_ts   the last row already shown (its id and ts): the next page
--              starts after it, even if that row has gone since
--   {items, more, unread}. Each item: the "down"'s words (alert_text), ts, and
--     endAt/endDay/endTime: when it went back, null while it hasn't
--     open: it has a "back" kind, none came yet, and no later alert of its kind on
--           that plant ended it; the app says "not back yet"
--     ids:  the "down" and "back" rows, for api_notifications_read
--   unread: every unread alert row, all time (the page's Mark all read).
-- ============================================================================

-- the "back" kind of an alert that starts something; null for a "back" itself
create or replace function private.alert_back_kind(p_kind text)
returns text language sql immutable as $$
  select case p_kind
    when 'grid_down' then 'grid_back' when 'logger_stale' then 'logger_back'
    when 'sunsynk_down' then 'sunsynk_back' when 'batt_hot' then 'batt_hot_back'
    when 'bank_drift' then 'bank_drift_back' when 'string_dead' then 'string_back' end
$$;

-- a "back" found from its "down" (pair_key) without reading every row
create index if not exists email_queue_pair_idx on public.email_queue (user_id, pair_key) where pair_key is not null;

create or replace function public.api_alerts(p_from timestamptz default null, p_switch text default null,
                                             p_unread boolean default false, p_before bigint default null,
                                             p_before_ts timestamptz default null, p_limit int default 50)
returns jsonb language sql stable security definer set search_path = '' as $$
  with a as (
    -- every alert the user can still see: plants still linked
    select q.id, q.kind, q.key, q.pair_key, q.plant_id, pu.plant_name, q.read_at, q.created_at, q.data
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid() and private.is_alert(q.kind)),
  e as (
    -- one row per alert: each start, and a "back" whose start is gone
    select s.*, b.id b_id, b.read_at b_read, b.created_at b_created, b.data b_data, b.kind b_kind
      from a s
      left join lateral (select x.* from public.email_queue x where x.user_id = auth.uid() and x.pair_key = s.key
                          order by x.id limit 1) b on true
     where (s.pair_key is null or not exists (select 1 from public.email_queue d where d.user_id = auth.uid() and d.key = s.pair_key))
       and (p_from is null or s.created_at >= p_from)
       and (p_switch is null or private.email_switch(s.kind) = p_switch)
       and (p_before is null or (s.created_at, s.id) < (p_before_ts, p_before))
       and (not p_unread or s.read_at is null or (b.id is not null and b.read_at is null))
     order by s.created_at desc, s.id desc
     limit greatest(1, least(p_limit, 200)) + 1),
  shown as (select * from e order by created_at desc, id desc limit greatest(1, least(p_limit, 200)))
  select jsonb_build_object(
    'more', (select count(*) from e) > greatest(1, least(p_limit, 200)),
    'unread', (select count(*) from a where read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'ts', s.created_at, 'kind', s.kind, 'plant', s.plant_id, 'plantName', s.plant_name,
        'read', s.read_at is not null and (s.b_id is null or s.b_read is not null),
        'ids', to_jsonb(array_remove(array[s.id, s.b_id], null)),
        'endAt', (bt->>'at')::bigint,
        'endDay', bt->>'day', 'endTime', bt->>'time',
        'open', s.b_id is null and coalesce(private.is_alert(private.alert_back_kind(s.kind)), false)
                and not exists (select 1 from public.email_queue l where l.user_id = auth.uid() and l.plant_id = s.plant_id
                                  and l.kind = s.kind and l.created_at > s.created_at))
        || t
        order by s.created_at desc, s.id desc) from shown s
        cross join lateral (select private.alert_text(s.kind, s.data, s.created_at, public.plant_tz(s.plant_id)) t) x
        left join lateral (select private.alert_text(s.b_kind, s.b_data, s.b_created, public.plant_tz(s.plant_id)) bt) y on true),
      '[]'::jsonb));
$$;

revoke all on function private.alert_back_kind(text) from public, anon, authenticated;
revoke all on function public.api_alerts(timestamptz, text, boolean, bigint, timestamptz, int) from public, anon;
grant execute on function public.api_alerts(timestamptz, text, boolean, bigint, timestamptz, int) to authenticated;
