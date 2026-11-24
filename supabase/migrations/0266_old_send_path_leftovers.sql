-- ============================================================================
-- 0266 — leftovers of the old send path (SOLAR-660, after SOLAR-645 step 7).
--
-- 0265 removed the old queue's senders, so an event row is never 'queued' or 'sending' again
-- and an alert's pop-up is always handed to the outbox at insert (pushed_at set).
--   1. msg.email_down_state, msg.push_down_state, email_history_open: the old-queue waits go.
--      A "down" sent on the old path before 0265 still counts as sent: a long outage's "back"
--      still pairs with it.
--   2. api_alerts_due, api_alerts_due_raw: only the alerts-due function read them (removed in
--      SOLAR-645 step 7, deleted from production 2026-11-24).
--
-- Bodies: email_down_state and email_history_open 0262/0263, push_down_state 0261; only the
-- lines marked 0266 change. No rows are written.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. no old-queue waits
-- ---------------------------------------------------------------------------
create or replace function msg.email_down_state(p_user uuid, p_pair_key text)
returns text language sql stable security definer set search_path = '' as $$
  select case
           when d.id is null then 'dropped'
           when d.status = 'outbox' then
             case (select o.status from msg.outbox o where o.dedupe_key = d.id || ':email')
               when 'queued' then 'wait' when 'sent' then 'ok' else 'dropped' end
           when d.status = 'sent' then 'ok'          -- sent on the old path, before 0265
           else 'dropped'                            -- 0266: no old-queue wait
         end
    from (select 1) one
    left join public.email_queue d on d.user_id is not distinct from p_user and d.key = p_pair_key
$$;

create or replace function msg.push_down_state(p_user uuid, p_pair_key text)
returns text language sql stable security definer set search_path = '' as $$
  select case
           when d.id is null then 'dropped'
           when d.push_skip = 'outbox' then
             case (select o.status from msg.outbox o where o.dedupe_key = d.id || ':push')
               when 'queued' then 'wait' when 'sent' then 'ok' else 'dropped' end
           -- pushed on the old path, before 0261; 0266: a row never handled no longer waits
           when d.pushed_at is not null and d.push_skip is null then 'ok'
           else 'dropped'
         end
    from (select 1) one
    left join public.email_queue d on d.user_id = p_user and d.key = p_pair_key
$$;

create or replace function public.email_history_open(p_user uuid, p_plant bigint)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.email_queue q
                  where q.user_id = p_user and q.plant_id = p_plant and q.kind = 'history'
                    and q.status = 'outbox'                                              -- 0266
                    and exists (select 1 from msg.outbox o where o.dedupe_key = q.id || ':email' and o.status = 'queued'))
$$;

-- ---------------------------------------------------------------------------
-- 2. the alerts-due readers
-- ---------------------------------------------------------------------------
drop function public.api_alerts_due(bigint);
drop function public.api_alerts_due_raw(bigint);
