-- ============================================================================
-- 0264 — one set of alert words (SOLAR-645 step 6, decision A).
--
-- The alert list, the pop-up and the email now take their words from one file,
-- supabase/functions/_shared/text.ts (alertLine, alertPush, alertMail), read by the edge
-- functions and by the app (public/build/text.js). The database sends the facts only:
--   api_alerts         each item also gets data (grid_notice_data, 0167), created (epoch s)
--                      and tz; the app works out title, body, at, tab, day and time from them
--   api_notifications  the same facts; the app reads only pinned from it
--   msg_push_take      data, created, tz, plant_name, plants in place of title, body, tab, day
--   push_claim         the same (old path, still there for a flip back until step 7)
-- private.push_text (0229) is dropped. private.alert_text (0233) stays until step 7, only so
-- api_alerts and api_notifications still send the old words to an app tab opened before the
-- release (the app has no reload on a new version); the app built from this change ignores
-- them. Step 7 drops alert_text and those keys.
--
-- Bodies: msg_push_take 0261, api_alerts 0232, api_notifications 0252, push_claim 0232 with
-- the 0256, 0257 and 0261 patches; only the lines marked 0264 change. No rows are written.
--
-- Order: notify and notify-push first (they read either shape), then the app (it reads
-- either shape), then this.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. msg_push_take: the facts
-- ---------------------------------------------------------------------------
drop function public.msg_push_take(int);
create function public.msg_push_take(p_limit int default 200)
returns table (id bigint, claim uuid, event_id bigint, kind text, plant_id bigint, data jsonb, created numeric,
               tz text, plant_name text, plants int, endpoint text, p256dh text, auth text)
language plpgsql security definer set search_path = '' as $$
declare
  v_claim uuid := gen_random_uuid();
  r msg.outbox;
  v_why text;
  v_n int;
begin
  -- 1. a lease that ran out: the reply was lost or the worker died. It goes again.
  update msg.push_sends s set status = 'queued', claim = null, claimed_until = null, updated_at = now()
   where s.status = 'sending' and s.claimed_until < now();

  -- 2. sends whose device was removed, then sends past their event's expiry
  update msg.push_sends s set status = 'gone', last_error = 'device removed', updated_at = now()
   where s.status = 'queued' and s.sub_id is null;
  update msg.push_sends s set status = 'failed', last_error = 'too old', updated_at = now()
    from msg.outbox o
   where o.id = s.outbox_id and s.status = 'queued' and o.expires_at <= now();

  -- 3. settle rows with nothing left open
  perform msg.push_settle(array(
    select o.id from msg.outbox o
     where o.channel = 'push' and o.status = 'queued' and o.claimed_until is not null
       and not exists (select 1 from msg.push_sends s where s.outbox_id = o.id and s.status in ('queued', 'sending'))));

  -- 4. new rows: guard, then one send per device
  for r in
    select o.* from msg.outbox o
     where o.channel = 'push' and o.status = 'queued' and o.claimed_until is null and o.not_before <= now()
       and msg.push_guard(o) is distinct from 'wait'           -- waiting rows never fill the take
     order by o.lane = 'urgent' desc, o.not_before, o.id
     limit p_limit
     for update skip locked
  loop
    v_why := msg.push_guard(r);
    if v_why = 'wait' then continue; end if;                  -- its "down" moved on since the select
    if v_why is not null then
      update msg.outbox o set status = 'dropped', drop_reason = v_why, done_at = now() where o.id = r.id;
      continue;
    end if;
    insert into msg.push_sends (outbox_id, sub_id)
    select r.id, ps.id
      from public.push_subs ps
      join public.email_queue q on q.id = r.event_id
     where ps.user_id = r.user_id and ps.platform = 'web'
       -- a "back" goes only to the devices that took its "down" through the outbox
       and (q.pair_key is null
            or not exists (select 1 from public.email_queue d
                            where d.user_id = q.user_id and d.key = q.pair_key and d.push_skip = 'outbox')
            or ps.id in (select s.sub_id from public.email_queue d
                           join msg.outbox od on od.dedupe_key = d.id || ':push'
                           join msg.push_sends s on s.outbox_id = od.id and s.status = 'sent'
                          where d.user_id = q.user_id and d.key = q.pair_key));
    get diagnostics v_n = row_count;
    if v_n = 0 then
      update msg.outbox o set status = 'dropped', drop_reason = 'no device', done_at = now() where o.id = r.id;
    else
      update msg.outbox o set claimed_until = o.expires_at, tries = o.tries + 1 where o.id = r.id;
    end if;
  end loop;

  -- 5. lease due sends under one claim
  return query
  with leased as (
    update msg.push_sends s
       set status = 'sending', claim = v_claim, claimed_until = now() + interval '2 minutes',
           tries = s.tries + 1, updated_at = now()
     where s.id in (select s2.id from msg.push_sends s2
                      join msg.outbox o2 on o2.id = s2.outbox_id
                     where s2.status = 'queued' and s2.not_before <= now() and o2.expires_at > now()
                       and s2.sub_id is not null
                     order by o2.lane = 'urgent' desc, s2.not_before, s2.id
                     limit p_limit
                     for update of s2 skip locked)
    returning s.id, s.outbox_id, s.sub_id)
  select l.id, v_claim, q.id, q.kind, q.plant_id,
         q.data, extract(epoch from q.created_at), public.plant_tz(q.plant_id), pu.plant_name,     -- 0264
         (select count(*)::int from public.plant_users n where n.user_id = q.user_id),
         ps.endpoint, ps.p256dh, ps.auth
    from leased l
    join msg.outbox o on o.id = l.outbox_id
    join public.email_queue q on q.id = o.event_id
    join public.push_subs ps on ps.id = l.sub_id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
   order by l.id;
end $$;

revoke all on function public.msg_push_take(int) from public, anon, authenticated;
grant execute on function public.msg_push_take(int) to service_role;

-- ---------------------------------------------------------------------------
-- 2. push_claim: the facts. Patched from its live body, as 0256, 0257 and 0261 did.
-- ---------------------------------------------------------------------------
do $$
declare
  d text := pg_get_functiondef('public.push_claim(int)'::regprocedure);
  head_old text := 'RETURNS TABLE(id bigint, user_id uuid, kind text, plant_id bigint, title text, body text, tab text, day text, subs jsonb)';
  cols_old text := $o$         pt.title,                                                                -- 0229
         pt.body,                                                                 -- 0229
         t->>'tab',
         case when t->>'tab' in ('grid', 'solar') then t->>'day' end,$o$;
  join_old text := $o$    cross join lateral (select private.alert_text(q.kind, q.data, q.created_at, public.plant_tz(q.plant_id)) t) x
    cross join lateral private.push_text(q.kind, x.t, pu.plant_name,                -- 0229
      (select count(*)::int from public.plant_users n where n.user_id = q.user_id)) pt
$o$;
begin
  if position(head_old in d) = 0 or position(cols_old in d) = 0 or position(join_old in d) = 0 then
    raise exception 'push_claim changed since 0261: edit it by hand';
  end if;
  d := replace(d, head_old, 'RETURNS TABLE(id bigint, user_id uuid, kind text, plant_id bigint, data jsonb, created numeric, tz text, plant_name text, plants integer, subs jsonb)');
  d := replace(d, cols_old, $n$         q.data, extract(epoch from q.created_at), public.plant_tz(q.plant_id), pu.plant_name,     -- 0264
         (select count(*)::int from public.plant_users n where n.user_id = q.user_id),$n$);
  d := replace(d, join_old, '');
  drop function public.push_claim(int);
  execute d;
end $$;
revoke all on function public.push_claim(int) from public, anon, authenticated;
grant execute on function public.push_claim(int) to service_role;

-- ---------------------------------------------------------------------------
-- 3. api_alerts: the facts
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
        -- 0264: the facts; the app writes the words (text.ts alertLine). t: the old words, for
        -- app tabs opened before the release only, dropped in step 7
        || t || jsonb_build_object('switch', private.alert_group(s.kind),
             'data', private.grid_notice_data(s.plant_id, s.kind, s.data),                                -- 0167
             'created', extract(epoch from s.created_at), 'tz', public.plant_tz(s.plant_id))
        order by s.created_at desc, s.id desc) from shown s
        cross join lateral (select private.alert_text(s.kind, private.grid_notice_data(s.plant_id, s.kind, s.data),   -- 0167
                                                      s.created_at, public.plant_tz(s.plant_id)) t) x),
      '[]'::jsonb));
$function$;

-- ---------------------------------------------------------------------------
-- 4. api_notifications: the facts (the app reads pinned only; the phone apps are not in use)
-- ---------------------------------------------------------------------------
create or replace function public.api_notifications()
returns jsonb language sql stable security definer set search_path = '' as $$
  with n as (
    select q.id, q.kind, q.plant_id, pu.plant_name, q.read_at, q.created_at, q.data,
           private.alert_text(q.kind, q.data, q.created_at, public.plant_tz(q.plant_id)) t   -- old words, until step 7
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
        'id', id, 'kind', kind, 'plant', plant_id, 'plantName', plant_name, 'read', read_at is not null) || t || jsonb_build_object(
        'data', data, 'created', extract(epoch from created_at), 'tz', public.plant_tz(plant_id),        -- 0264
        'switch', private.alert_group(kind))
        order by created_at desc, id desc) from n), '[]'::jsonb));
$$;

-- ---------------------------------------------------------------------------
-- 5. the pop-up's SQL words go (alert_text: step 7)
-- ---------------------------------------------------------------------------
drop function private.push_text(text, jsonb, text, int);
