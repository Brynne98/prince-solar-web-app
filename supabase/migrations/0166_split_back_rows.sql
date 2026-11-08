-- ============================================================================
-- 0166 — An alert and its "back" are two rows again (SOLAR-431).
--
-- 0152 folded each "back" into its start's row ("14:55 to 19:24, 4h 29m"), and SOLAR-411
-- put the bell on the same list. On 8 Nov Grid down at 14:55 and Grid back at 19:24
-- read as one notice. Now every alert row is its own item, at its own time, with its own
-- words ("Grid back. Back after 4h 29m."). Filters, paging and unread apply per row.
-- A start with no back yet still says "not back yet" (open), as in 0152.
--
-- Body: 0158's api_alerts with the pairing taken out. Reversible: re-run 0158's body.
-- ============================================================================

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
        cross join lateral (select private.alert_text(s.kind, s.data, s.created_at, public.plant_tz(s.plant_id)) t) x),
      '[]'::jsonb));
$$;
