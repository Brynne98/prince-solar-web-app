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
      join plants.user_plants pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
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
