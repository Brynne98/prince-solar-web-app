-- ============================================================================
-- 0147 — "Need a hand adding your plant?" the day after sign-up (SOLAR-319).
--
-- Queued with the welcome email when the address is confirmed (or arrives confirmed,
-- as with Google), due 24 hours later. unique (user_id, key): confirming again queues
-- nothing new, so one email per account. email_claim skips it if the account has any
-- SunSynk login by then, a disconnected or dead one too: those people have a different
-- problem. No switch, like welcome. Accounts made before this get none.
-- ============================================================================

create or replace function private.email_on_confirm()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.email_confirmed_at is not null and (tg_op = 'INSERT' or old.email_confirmed_at is null)
     and new.email is not null then
    insert into public.email_queue (user_id, kind, key, priority) values (new.id, 'welcome', 'welcome', 1)
    on conflict do nothing;
    insert into public.email_queue (user_id, kind, key, priority, due_at)
    values (new.id, 'need_a_hand', 'need_a_hand', 1, now() + interval '24 hours')
    on conflict do nothing;
  end if;
  return null;
end $$;

-- As 0102, plus the need_a_hand skip.
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
         q.kind, q.key, q.data, q.tries, private.email_switch(q.kind),
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

