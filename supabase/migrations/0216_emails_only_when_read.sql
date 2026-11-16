-- ============================================================================
-- 0216 — three emails to an account that cannot read the plant (SOLAR-572).
--
-- Before:
--   - history ("Your last 60 days are in") went to every account linked to a plant
--     whose history is loaded, also one at the pay screen (a new account on a plant
--     that had its free week).
--   - free_week_setup ("Finish your setup", day 2) went to an account that never
--     had a free week.
--   - unpaid_last ("Your history is deleted in 3 days") went to an account with no
--     plan when a paying account, or one in its week, has the same plant. That
--     history stays.
--
-- Now:
--   - email_claim skips a history row when the plant is not read for that account
--     (plant_live, 0204). Asked when the email is sent, not when it is queued: the
--     row is queued inside the link, before the account's week row is written.
--   - free_week_mail: free_week_setup only while the first plant is read for the
--     account; unpaid_last only when a running plant of the account is read for
--     nobody (not in live_plants, 0205).
--   - email_on_history: when a plant's history finishes loading again (a payment
--     starts the 60-day fetch), a history row skipped as 'not read' is removed
--     first, so the account that now pays gets the email.
-- Bodies are 0102's, 0214's and 0215's otherwise.
-- ============================================================================

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
           when q.kind = 'history' and q.user_id is not null and q.plant_id is not null
                and not private.plant_live(q.user_id, q.plant_id)
             then 'not read'
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
                then coalesce(q.data, '{}'::jsonb) || '{"choose": true}'::jsonb
              else q.data end,
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


CREATE OR REPLACE FUNCTION private.free_week_mail()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare n int;
begin
  with fw as (
    -- a week it had (not ended at the start), not ended by a plan
    select f.user_id, min(f.started_at) as started, private.week_ends(f.user_id) as ends
      from private.free_week_logins f
      left join private.billing b on b.user_id = f.user_id
     where coalesce(b.plan, 'free') = 'free' and f.over_why is distinct from 'plan'
       and least(f.started_at + interval '7 days', coalesce(f.over_at, 'infinity')) > f.started_at
     group by f.user_id
  ), first_plant as (
    select distinct on (pu.user_id) pu.user_id, pu.plant_id, pu.linked_at
      from public.plant_users pu where not pu.paused
     order by pu.user_id, pu.linked_at, pu.plant_id
  ), setup as (
    -- Day 2 after the account's first plant, while that plant is read for it; Hide on the app's card doesn't stop it.
    select fp.user_id, fp.plant_id, private.setup_steps_open(fp.plant_id) as steps,
           c.has_battery is distinct from false as battery
      from first_plant fp left join public.plant_config c on c.plant_id = fp.plant_id
     where now() >= fp.linked_at + interval '2 days' and now() < fp.linked_at + interval '3 days'
       and private.plant_live(fp.user_id, fp.plant_id)
  ), unpaid as (
    select f.user_id, private.unpaid_since(f.user_id) as since
      from (select user_id from private.free_week_logins
             union select user_id from private.billing where ended_at is not null) f
     where exists (select 1 from public.plant_users pu where pu.user_id = f.user_id and not pu.paused)
       and not private.no_week(f.user_id)
  )
  insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
  select s.user_id, s.plant_id, 'free_week_setup', 'free_week_setup:' || s.user_id,
         jsonb_build_object('steps', to_jsonb(s.steps), 'battery', s.battery), 1
    from setup s
   where cardinality(s.steps) > 0
  union all
  select fw.user_id, fp.plant_id, 'free_week_soon', 'free_week_soon:' || fw.user_id,
         jsonb_build_object('endsAt', extract(epoch from fw.ends)::bigint,
           'plants', (select count(*) from private.plant_picks p where p.user_id = fw.user_id),
           'perMonth', round(public.billing_amount('home', 'yearly', 0,
                         private.billing_offer_open(fw.user_id, private.billing_today())) / 12.0)::int), 1
    from fw left join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.ends - interval '2 days' and now() < fw.ends - interval '1 day'
  union all
  select fw.user_id, fp.plant_id, 'report_week', 'report_week:free:' || fw.user_id,
         jsonb_build_object('today', timezone(public.plant_tz(fp.plant_id), now())::date, 'freeWeekEnds', true,
           'plants', (select count(*) from private.plant_picks p where p.user_id = fw.user_id),
           'from', timezone(public.plant_tz(fp.plant_id), fw.ends - interval '7 days')::date), 2
    from fw join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.ends and now() < fw.ends + interval '1 day'
  union all
  select u.user_id, null, k.kind, k.kind || ':' || u.user_id || ':' || u.since::date,
         jsonb_build_object('since', extract(epoch from u.since)::bigint,
           'deleteAt', extract(epoch from u.since + interval '30 days')::bigint,
           'plants', (select count(*) from private.plant_picks p where p.user_id = u.user_id),
           'paid', private.had_plan(u.user_id)), 1
    from unpaid u
   cross join (values ('unpaid_reminder', 14), ('unpaid_last', 27)) k(kind, day)
   where now() >= u.since + make_interval(days => k.day) and now() < u.since + make_interval(days => k.day + 1)
     -- 'deleted in 3 days' only when a plant of the account will be deleted: one not read for another account
     and (k.kind <> 'unpaid_last'
          or exists (select 1 from public.plant_users pu
                      where pu.user_id = u.user_id and not pu.paused
                        and pu.plant_id not in (select public.live_plants())))
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $function$
;
revoke all on function private.free_week_mail() from public, anon, authenticated;

-- 0102's email_on_history. Added: a row skipped as 'not read' makes way for a new one.
create or replace function private.email_on_history()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if private.history_done(new) and not private.history_done(old) then
    delete from public.email_queue q
     where q.plant_id = new.plant_id and q.kind = 'history' and q.status = 'skipped' and q.last_error = 'not read';
    perform private.email_enqueue_plant(new.plant_id, 'history', 'history:' || new.plant_id, '{}'::jsonb, null, 1::smallint);
  end if;
  return null;
end $$;

notify pgrst, 'reload schema';
