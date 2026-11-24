-- ============================================================================
-- 0265 — the old send path goes (SOLAR-645 step 7).
--
-- Every alert, pop-up and email has gone through msg.outbox since 0261-0264; share_down and
-- share_back (a shared plant's login stopped, came back) were the last kinds on the old
-- queue. This moves them, then removes what only the old path used:
--   1. share_down, share_back: email, urgent lane, 1 h, like the other alerts. They have no
--      switch and no pop-up (not in is_alert). The guard checks the plant is still chosen and
--      read at send time; the old path checked that only at insert (email_skip_unchosen).
--   2. msg.kinds.route can only be 'outbox': there is no old path to flip back to.
--   3. Rows still waiting on the old queue (none in production on 2026-11-25; a share row
--      written between the functions' deploy and this migration could be): moved to the
--      outbox when their kind has an email route, else marked skipped.
--   4. Dropped: email_claim, email_done, push_claim, push_done (notify's old loops, gone from
--      the functions in the same change); email_queue_old_billing and old_billing_email
--      (dropped billing kinds nothing writes since 0252).
--   5. api_alerts, api_notifications: the old word keys go (title, body, at, tab, day, time),
--      kept in 0264 for app tabs opened before v0.63.4; then private.alert_text goes.
--
-- Bodies: api_alerts and api_notifications as in 0264; only the lines marked 0265 change.
--
-- Point of no return: after this, a kind can't go back to the old path.
-- Order: notify, notify-email, notify-push deployed first (they no longer call the dropped
-- functions), then the app (it no longer reads the old word keys), then this.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. share_down, share_back to the outbox
-- ---------------------------------------------------------------------------
insert into msg.kinds (kind, channel, route, lane, ttl) values
  ('share_down', 'email', 'outbox', 'urgent', interval '1 hour'),
  ('share_back', 'email', 'outbox', 'urgent', interval '1 hour')
on conflict (kind, channel) do update set route = excluded.route, lane = excluded.lane, ttl = excluded.ttl;

-- ---------------------------------------------------------------------------
-- 2. outbox only
-- ---------------------------------------------------------------------------
alter table msg.kinds alter column route set default 'outbox';
update msg.kinds set route = 'outbox' where route <> 'outbox';
alter table msg.kinds drop constraint kinds_route_check;
alter table msg.kinds add constraint kinds_route_check check (route = 'outbox');

-- ---------------------------------------------------------------------------
-- 3. what is left on the old queue
-- ---------------------------------------------------------------------------
-- the same rows and times as msg.route_event_rows (0261)
with moved as (
  update public.email_queue q set status = 'outbox', claimed_at = null
   where q.status in ('queued', 'sending')
     and exists (select 1 from msg.kinds k where k.kind = q.kind and k.channel = 'email')
  returning q.*)
insert into msg.outbox (event_id, channel, lane, kind, user_id, to_email, dedupe_key, not_before, expires_at)
select m.id, 'email', k.lane, m.kind, m.user_id,
       coalesce(m.to_email, (select u.email::text from auth.users u where u.id = m.user_id)),
       m.id || ':email', m.due_at, greatest(m.due_at, m.created_at) + k.ttl
  from moved m join msg.kinds k on k.kind = m.kind and k.channel = 'email'
on conflict (dedupe_key) do nothing;

update public.email_queue q set status = 'skipped', claimed_at = null, last_error = 'old path removed (0265)'
 where q.status in ('queued', 'sending');

-- ---------------------------------------------------------------------------
-- 4. the old path's functions
-- ---------------------------------------------------------------------------
drop function public.email_claim(int, boolean, text);
drop function public.email_done(jsonb);
drop function public.push_claim(int);
drop function public.push_done(text[], text[]);
drop trigger email_queue_old_billing on public.email_queue;
drop function private.email_queue_old_billing();
drop function billing.old_billing_email(text);

-- ---------------------------------------------------------------------------
-- 5. api_alerts, api_notifications: facts only; then alert_text goes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.api_alerts(p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_switch text DEFAULT NULL::text, p_unread boolean DEFAULT false, p_before bigint DEFAULT NULL::bigint, p_before_ts timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with raw as (
    -- every alert the user can still see: plants still linked, and readable (0204)
    select q.id, q.kind, q.key, q.plant_id, pu.plant_name, q.read_at, q.created_at, q.data, q.status,
           -- one login stopping (or coming back) writes a row per plant: one group (0232)
           -- (rows from before 0158 have no since: each stays its own)
           coalesce(case when q.kind in ('needs_relink', 'relinked') and q.data ? 'since'
                         then q.kind || ':' || coalesce(q.data->>'account', '') || ':' || (q.data->>'since') end,
                    q.id::text) grp
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid() and private.is_alert(q.kind)
       and q.plant_id in (select public.my_plant_ids())),
  a as (
    -- each group shows once, on its emailed row when readable; read when every row is
    select z.* from (
      select r.*, jsonb_agg(r.id) over w ids, bool_and(r.read_at is not null) over w is_read,
             row_number() over (partition by r.grp order by r.status = 'skipped', r.id) rn
        from raw r window w as (partition by r.grp)) z
     where z.rn = 1),
  e as (
    select s.* from a s
     where (p_from is null or s.created_at >= p_from)
       and (p_switch is null or private.alert_group(s.kind) = p_switch)
       and (p_before is null or (s.created_at, s.id) < (p_before_ts, p_before))
       and (not p_unread or not s.is_read)
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
    'unread', (select count(*) from a where not is_read),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'ts', s.created_at, 'kind', s.kind, 'plant', s.plant_id, 'plantName', s.plant_name,
        'read', s.is_read,
        'ids', s.ids,
        'open', coalesce(private.is_alert(private.alert_back_kind(s.kind)), false)
                and not exists (select 1 from public.email_queue b where b.user_id = auth.uid() and b.pair_key = s.key)
                and coalesce(s.created_at >= (select f.at from firsts f where f.kind = private.alert_back_kind(s.kind)), false)
                and not exists (select 1 from public.email_queue l where l.user_id = auth.uid() and l.plant_id = s.plant_id
                                  and l.kind = s.kind and l.created_at > s.created_at))
        -- the facts; the app writes the words (text.ts alertLine, 0264). 0265: no old words
        || jsonb_build_object('switch', private.alert_group(s.kind),
             'data', private.grid_notice_data(s.plant_id, s.kind, s.data),                                -- 0167
             'created', extract(epoch from s.created_at), 'tz', public.plant_tz(s.plant_id))
        order by s.created_at desc, s.id desc) from shown s),
      '[]'::jsonb));
$function$;

create or replace function public.api_notifications()
returns jsonb language sql stable security definer set search_path = '' as $$
  with n as (
    select q.id, q.kind, q.plant_id, pu.plant_name, q.read_at, q.created_at, q.data
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid()
       and q.plant_id in (select public.my_plant_ids())
       and private.is_alert(q.kind)
       and q.created_at > now() - interval '30 days'
     order by q.created_at desc, q.id desc
     limit 300)
  select jsonb_build_object(
    'pinned', '[]'::jsonb,
    'unread', (select count(*) from n where read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'plant', plant_id, 'plantName', plant_name, 'read', read_at is not null) || jsonb_build_object(   -- 0265: no old words
        'data', data, 'created', extract(epoch from created_at), 'tz', public.plant_tz(plant_id),        -- 0264
        'switch', private.alert_group(kind))
        order by created_at desc, id desc) from n), '[]'::jsonb));
$$;

drop function private.alert_text(text, jsonb, timestamptz, text);
