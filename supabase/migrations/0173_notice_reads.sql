-- ============================================================================
-- 0173 — Billing notices can be read (SOLAR-465).
--
-- The billing notices (0148) are read from the billing state and stored nowhere, so
-- the bell counted each one as unread until its state ended. Now each has a key from
-- its facts, and a seen key is kept per user:
--
--   private.notice_key(p)     kind:md5 of the notice's facts, less the day count that
--                             free_week_soon moves daily. New facts (another booked
--                             change, a later failed try) are a new, unread notice.
--   private.notice_reads      the keys a user has seen.
--   api_notifications()       0151's, each pinned notice with key and read.
--   api_notices_read(keys)    marks those keys read; null marks every pinned one.
--   api_notifications_read    0151's; null (Mark all read) marks the notices too.
-- ============================================================================

create table if not exists private.notice_reads (
  user_id  uuid not null references auth.users (id) on delete cascade,
  key      text not null,
  read_at  timestamptz not null default now(),
  primary key (user_id, key)
);
revoke all on table private.notice_reads from public, anon, authenticated;
grant all on table private.notice_reads to service_role;

create or replace function private.notice_key(p jsonb)
returns text language sql immutable set search_path = '' as $$
  select (p->>'kind') || ':' || md5((p - 'days')::text);
$$;

create or replace function public.api_notifications()
returns jsonb language sql stable security definer set search_path = '' as $$
  with n as (
    select q.id, q.kind, q.plant_id, pu.plant_name, q.read_at, q.created_at,
           private.alert_text(q.kind, q.data, q.created_at, public.plant_tz(q.plant_id)) t
      from public.email_queue q
      join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
     where q.user_id = auth.uid()
       and private.is_alert(q.kind)
       and q.created_at > now() - interval '30 days'
     order by q.created_at desc, q.id desc
     limit 300)
  select jsonb_build_object(
    'pinned', coalesce((select jsonb_agg(p || jsonb_build_object('key', k, 'read',
        exists (select 1 from private.notice_reads r where r.user_id = auth.uid() and r.key = k)) order by o)
        from jsonb_array_elements(private.billing_notices()) with ordinality as e(p, o),
             lateral private.notice_key(p) k), '[]'::jsonb),
    'unread', (select count(*) from n where read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'kind', kind, 'plant', plant_id, 'plantName', plant_name, 'read', read_at is not null) || t
        order by created_at desc, id desc) from n), '[]'::jsonb));
$$;

create or replace function public.api_notices_read(p_keys text[] default null)
returns void language sql security definer set search_path = '' as $$
  insert into private.notice_reads (user_id, key)
  select auth.uid(), k
    from unnest(coalesce(p_keys, (select array_agg(private.notice_key(p))
                                    from jsonb_array_elements(private.billing_notices()) p))) k
   where auth.uid() is not null and k is not null
  on conflict do nothing;
$$;

create or replace function public.api_notifications_read(p_ids bigint[] default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.email_queue
     set read_at = now()
   where user_id = auth.uid() and read_at is null
     and private.is_alert(kind)
     and (p_ids is null or id = any (p_ids));
  if p_ids is null then perform public.api_notices_read(null); end if;
end $$;

revoke all on function private.notice_key(jsonb) from public, anon, authenticated;
revoke all on function public.api_notices_read(text[]) from public, anon;
grant execute on function public.api_notices_read(text[]) to authenticated;
