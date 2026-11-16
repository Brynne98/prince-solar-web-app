-- ============================================================================
-- 0210 — "Need a hand" also goes to a login whose plants all wait to be chosen (SOLAR-567).
--
-- Before (0147): need_a_hand was skipped once the account had any SunSynk login. A
-- login with 6 or more plants links them all locked (the free week runs 5); an owner
-- who closed the Choose plants pop-up started no week and got no email at all.
--
-- Now, a day after sign-up, the account still gets need_a_hand when all of these hold:
-- it has a login, it has plants, none of them runs, it has no paid plan, and its free
-- week never started. data.choose = true tells notify to send the choose-plants
-- version. Any other account with a login is skipped as before. Paid accounts are
-- left out on purpose.
-- ============================================================================

create or replace function private.pick_waiting(p_user uuid)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select exists (select 1 from public.plant_users pu where pu.user_id = p_user)
     and not exists (select 1 from public.plant_users pu where pu.user_id = p_user and not pu.paused)
     and coalesce((select b.plan from private.billing b where b.user_id = p_user), 'free') = 'free'
     and not exists (select 1 from private.free_week_logins f where f.user_id = p_user)
$$;
revoke all on function private.pick_waiting(uuid) from public, anon, authenticated;

-- As 0147, plus: need_a_hand with a login is kept when pick_waiting, and carries choose.
create or replace function public.email_claim(p_limit int, p_peek boolean default false)
returns table (id bigint, user_id uuid, to_email text, plant_id bigint, plant_name text, tz text,
               kind text, key text, data jsonb, tries int, switch text, unsub_token uuid, batch_key text)
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if not p_peek then
    -- A sender that died mid-batch: its claims go back on the queue.
    update public.email_queue q set status = 'queued', claimed_at = null
     where q.status = 'sending' and q.claimed_at < now() - interval '10 minutes';
  end if;

  create temp table if not exists _claim (id bigint primary key, skip text) on commit drop;
  truncate _claim;
  insert into _claim (id, skip)
  select q.id,
         case
           when sw is not null and q.user_id is not null and not public.email_wanted(q.user_id, sw) then 'switched off'
           when q.plant_id is not null and q.user_id is not null and q.kind <> 'needs_relink'
                and not exists (select 1 from public.plant_users pu where pu.user_id = q.user_id and pu.plant_id = q.plant_id)
             then 'plant removed'
           when q.kind = 'welcome' and exists (select 1 from public.plant_users pu where pu.user_id = q.user_id)
             then 'plant linked'
           when q.kind = 'need_a_hand' and exists (select 1 from private.sunsynk_accounts a where a.user_id = q.user_id)
                and not private.pick_waiting(q.user_id)
             then 'login added'
           when q.pair_key is not null and not exists (
                  select 1 from public.email_queue d where d.user_id is not distinct from q.user_id and d.key = q.pair_key
                     and d.status in ('sent', 'sending', 'queued'))
             then 'down not sent'
         end
    from (select q0.*, private.email_switch(q0.kind) as sw
            from public.email_queue q0
           where q0.status = 'queued' and q0.due_at <= now()
             -- a "back" waits while its "down" is still on its way
             and not exists (select 1 from public.email_queue d
                              where q0.pair_key is not null and d.user_id is not distinct from q0.user_id and d.key = q0.pair_key
                                and (d.status = 'sending' or (d.status = 'queued' and d.due_at > now())))
           order by q0.priority, q0.due_at, q0.id
           limit p_limit
           for update skip locked) q;

  if not p_peek then
    update public.email_queue q set status = 'skipped', last_error = c.skip
      from _claim c where c.id = q.id and c.skip is not null;
    update public.email_queue q set status = 'sending', claimed_at = now(), tries = q.tries + 1
      from _claim c where c.id = q.id and c.skip is null;
  end if;

  return query
  select q.id, q.user_id, coalesce(q.to_email, u.email::text), q.plant_id,
         coalesce(pu.plant_name, (select pu2.plant_name from public.plant_users pu2
                                   where pu2.user_id = q.user_id order by pu2.linked_at limit 1)),
         case when q.plant_id is not null then public.plant_tz(q.plant_id) else 'Africa/Johannesburg' end,
         q.kind, q.key,
         case when q.kind = 'need_a_hand' and exists (select 1 from private.sunsynk_accounts a where a.user_id = q.user_id)
              then coalesce(q.data, '{}'::jsonb) || '{"choose": true}'::jsonb else q.data end,
         q.tries, private.email_switch(q.kind),
         case when private.email_switch(q.kind) is not null and q.user_id is not null and not p_peek
              then public.email_unsub_token(q.user_id) end,
         q.batch_key
    from _claim c
    join public.email_queue q on q.id = c.id
    left join auth.users u on u.id = q.user_id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
   where c.skip is null
   order by q.priority, q.due_at, q.id;
end $$;
