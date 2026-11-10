-- SOLAR-451: shared plants restart on their own, and their owners are told.
--
-- The share login (kind 'share', 0172) used to stop for good on a SunSynk timeout
-- during its re-sign-in, and only its own user (the company) was mailed. poll now
-- treats a timeout as a failed poll and tries a refused share login again hourly
-- (_shared/sunsynk.ts, poll). Here: share_retry_due times that retry, and
-- email_on_relink mails the owners instead.
--
-- Body: 0164's email_on_relink, with only the share branch added at the top.
-- ============================================================================

create or replace function private.email_on_relink()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  now_s bigint := extract(epoch from now())::bigint;
  since_s bigint := coalesce(extract(epoch from old.last_ok_at)::bigint, extract(epoch from now())::bigint);  -- 0164: last good poll
  names jsonb;
  r record;
  n int := 0;
begin
  -- 0177: the share login. Each owner of a claimed shared plant gets one email when it
  -- stops and one when it is back. No sign-in wording: owners can't act on it. The
  -- company user, who owns the login, gets nothing.
  if new.kind = 'share' then
    if new.status = 'needs_relink' and old.status is distinct from 'needs_relink' then
      insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
      select o.user_id, o.plant_id, 'share_down', 'share_down:' || new.id || ':' || o.user_id || ':' || now_s,
             jsonb_build_object('account', new.id, 'since', since_s, 'plants', o.names), 0
        from (select pu.user_id, (array_agg(pu.plant_id order by pu.linked_at))[1] plant_id,
                     jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at) names
                from public.plant_users pu
               where pu.account_id = new.id and pu.via_share and pu.share_gone_at is null and not pu.paused
               group by pu.user_id) o
      on conflict do nothing;
    elsif old.status = 'needs_relink' and new.status = 'active' then
      -- each owner's latest "stopped" with no "back" yet; paired so email_claim drops a
      -- "back" whose "stopped" never went
      insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
      select d.user_id, d.plant_id, 'share_back', 'share_back:' || new.id || ':' || d.user_id || ':' || now_s, d.key,
             jsonb_build_object('account', new.id, 'since', coalesce((d.data->>'since')::bigint, extract(epoch from d.created_at)::bigint),
                                'at', now_s, 'plants', d.data->'plants'), 0
        from (select distinct on (q.user_id) q.* from public.email_queue q
               where q.kind = 'share_down' and q.data->>'account' = new.id::text
               order by q.user_id, q.id desc) d
       where not exists (select 1 from public.email_queue b where b.user_id = d.user_id and b.pair_key = d.key)
      on conflict do nothing;
    end if;
    return null;
  end if;

  -- every plant this user has on the login, oldest link first; the email lists them all
  select coalesce(jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at), '[]'::jsonb)
    into names
    from public.plant_users pu where pu.account_id = new.id and pu.user_id = new.user_id;

  if new.status = 'needs_relink' and old.status is distinct from 'needs_relink' then
    for r in select pu.plant_id from public.plant_users pu
              where pu.account_id = new.id and pu.user_id = new.user_id order by pu.linked_at loop
      n := n + 1;
      insert into public.email_queue (user_id, plant_id, kind, key, data, priority, status, last_error)
      values (new.user_id, r.plant_id, 'needs_relink', 'needs_relink:' || new.id || ':' || r.plant_id || ':' || now_s,
              jsonb_build_object('account', new.id, 'since', since_s, 'plants', names), 0,
              case when n = 1 then 'queued' else 'skipped' end, case when n > 1 then 'one email per login' end)
      on conflict do nothing;
    end loop;
    -- a login with no plant still gets its email, as before
    if n = 0 then
      insert into public.email_queue (user_id, kind, key, data, priority)
      values (new.user_id, 'needs_relink', 'needs_relink:' || new.id || ':' || now_s,
              jsonb_build_object('account', new.id, 'since', since_s, 'plants', names), 0)
      on conflict do nothing;
    end if;

  elsif old.status = 'needs_relink' and new.status = 'active' then
    -- each plant's latest dead-login row with no "back" yet
    for r in
      select d.plant_id, d.key, d.status, coalesce((d.data->>'since')::bigint, extract(epoch from d.created_at)::bigint) since
        from public.plant_users pu
        cross join lateral (select q.* from public.email_queue q
                             where q.user_id = new.user_id and q.plant_id = pu.plant_id and q.kind = 'needs_relink'
                               and q.data->>'account' = new.id::text
                             order by q.id desc limit 1) d
       where pu.account_id = new.id and pu.user_id = new.user_id
         and not exists (select 1 from public.email_queue b where b.user_id = new.user_id and b.pair_key = d.key)
       order by pu.linked_at
    loop
      -- the email goes on the plant whose "down" emailed, so email_claim pairs them
      insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority, status, last_error)
      values (new.user_id, r.plant_id, 'relinked', 'relinked:' || new.id || ':' || r.plant_id || ':' || now_s, r.key,
              jsonb_build_object('account', new.id, 'since', r.since, 'at', now_s, 'plants', names), 0,
              case when r.status <> 'skipped' then 'queued' else 'skipped' end,
              case when r.status = 'skipped' then 'one email per login' end)
      on conflict do nothing;
    end loop;
  end if;
  return null;
end $$;

-- The share login, when it is stopped and its last try (account_mark logs each as a
-- 'died' event) was 55+ minutes ago. poll's shard 0 asks every minute (SOLAR-451).
create or replace function public.share_retry_due()
returns uuid language sql stable security definer set search_path = '' as $$
  select a.id from private.sunsynk_accounts a
   where a.kind = 'share' and a.status = 'needs_relink'
     and coalesce((select max(e.at) from private.sunsynk_login_events e
                    where e.account_id = a.id and e.event = 'died'), '-infinity') < now() - interval '55 minutes'
$$;
revoke all on function public.share_retry_due() from public, anon, authenticated;
grant execute on function public.share_retry_due() to service_role;
