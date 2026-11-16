-- ============================================================================
-- 0213 — "Offers and reminders": one switch for every email that offers a plan (SOLAR-569).
--
-- Before: 'reminders' (0206) held the day 21, 34 and 37 emails. Unsubscribe in one of
-- them turned it off, and the app could not turn it back on: the owner had no column
-- right on it. Day 5 (free_week_soon), day 7 (the free week's last report) and the
-- plan-ended email (winback) offer a plan with no opt-out (POPIA s69(4)).
--
-- Now:
--   - The owner may read and set email_prefs.reminders, so the app shows it as a switch.
--   - free_week_soon and winback sit behind 'reminders'.
--   - The day-7 row is a report_week with data.freeWeekEnds; it sits behind 'reminders',
--     not 'weekly'. private.email_switch_of() reads the row's data for that.
--   - All of them carry the unsubscribe token, so notify can put the link in the footer.
-- ============================================================================

grant select (reminders), insert (reminders), update (reminders) on public.email_prefs to authenticated;

-- 0207's email_switch, with day 5 and the plan-ended email.
create or replace function private.email_switch(p_kind text)
returns text language sql immutable as $$
  select case
    when p_kind in ('grid_down', 'grid_back') then 'grid'
    when p_kind in ('batt_hot', 'batt_hot_back', 'bank_drift', 'bank_drift_back') then 'battery'
    when p_kind in ('string_dead', 'string_back') then 'panels'
    when p_kind in ('logger_stale', 'logger_back') then 'readings'
    when p_kind in ('sunsynk_down', 'sunsynk_back') then 'sunsynk'
    when p_kind = 'report_week' then 'weekly'
    when p_kind = 'report_month' then 'monthly'
    when p_kind = 'report_year' then 'yearly'
    when p_kind in ('unpaid_reminder', 'unpaid_last', 'unpaid_deleted', 'free_week_soon', 'winback') then 'reminders'
  end
$$;

-- A queued row's switch: as email_switch, but the free week's day-7 report is an offer.
create or replace function private.email_switch_of(p_kind text, p_data jsonb)
returns text language sql immutable as $$
  select case when p_kind = 'report_week' and p_data->>'freeWeekEnds' = 'true' then 'reminders'
              else private.email_switch(p_kind) end
$$;
revoke all on function private.email_switch_of(text, jsonb) from public, anon, authenticated;

-- 0210's email_claim. Changed: the switch is email_switch_of(kind, data), worked out once.
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

  create temp table if not exists _claim (id bigint primary key, skip text, sw text) on commit drop;
  truncate _claim;
  insert into _claim (id, skip, sw)
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
         end,
         sw
    from (select q0.*, private.email_switch_of(q0.kind, q0.data) as sw
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
         q.tries, c.sw,
         case when c.sw is not null and q.user_id is not null and not p_peek
              then public.email_unsub_token(q.user_id) end,
         q.batch_key
    from _claim c
    join public.email_queue q on q.id = c.id
    left join auth.users u on u.id = q.user_id
    left join public.plant_users pu on pu.user_id = q.user_id and pu.plant_id = q.plant_id
   where c.skip is null
   order by q.priority, q.due_at, q.id;
end $$;
