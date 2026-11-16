-- ============================================================================
-- 0217 — three emails to an account that cannot read the plant (SOLAR-572).
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
--   - unpaid_delete: the 'history has been deleted' email goes only to an account
--     whose 'deleted in 3 days' email was queued for this lapse. An account that
--     got no warning (a payer held the plant then) gets no email after the delete.
--   - api_link_status: each plant carries week_used, so the Choose plants pop-up
--     can say which plants have had their free week.
--   - had_plan: a payment that was taken, not applied and marked for refund
--     ('refund: ...', billing_charge_paid) no longer counts as a plan. Before, that
--     account lost the launch price and, with no plant yet, its free week.
-- Bodies are 0102's, 0209's, 0214's, 0215's and the latest api_link_status otherwise.
-- ============================================================================

-- 0207's had_plan. Added: not a payment marked for refund, which never became a plan.
create or replace function private.had_plan(p_user uuid)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select exists (select 1 from private.billing_charges c
                  where c.user_id = p_user and c.status = 'paid' and coalesce(c.error, '') not like 'refund%')
$$;
revoke all on function private.had_plan(uuid) from public, anon, authenticated;

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

-- 0209's unpaid_delete. Added: the email only after the warning.
CREATE OR REPLACE FUNCTION private.unpaid_delete()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  p bigint;
  plants int := 0;
  total bigint := 0;
begin
  for p in
    select pu.plant_id
      from public.plant_users pu
      left join private.billing b on b.user_id = pu.user_id
     where not pu.paused
     group by pu.plant_id
    having bool_and(not private.plant_live(pu.user_id, pu.plant_id)
                    and private.unpaid_since(pu.user_id) + interval '30 days' <= now()
                    and (b.keep_until is null or b.keep_until < private.billing_today()))
     order by pu.plant_id
  loop
    perform pg_advisory_xact_lock(p);
    -- a payment or a link that landed while this run waited for the lock
    continue when exists (select 1 from public.plant_users pu
                           where pu.plant_id = p and not pu.paused
                             and (private.plant_live(pu.user_id, p)
                                  or private.unpaid_since(pu.user_id) + interval '30 days' > now()));
    continue when not (exists (select 1 from public.agg_minute where plant_id = p)
                    or exists (select 1 from public.agg_5m where plant_id = p)
                    or exists (select 1 from public.readings where plant_id = p)
                    or exists (select 1 from public.plant_energy where plant_id = p)
                    or exists (select 1 from public.grid_off where plant_id = p));
    plants := plants + 1;
    total := total + (select coalesce(sum(v::bigint), 0) from jsonb_each_text(private.plant_readings_delete(p)) as t(k, v));
    update public.plant_config
       set backfill_next = null, backfill_until = null, backfill_tries = 0, temp_next = null
     where plant_id = p;
    -- the day-37 email, to each account with no plan that runs the plant: once per lapse
    insert into public.email_queue (user_id, kind, key, data, priority)
    select pu.user_id, 'unpaid_deleted', 'unpaid_deleted:' || pu.user_id || ':' || private.unpaid_since(pu.user_id)::date,
           jsonb_build_object('plants', (select count(*) from private.plant_picks k where k.user_id = pu.user_id),
             'paid', private.had_plan(pu.user_id)), 1
      from public.plant_users pu
     where pu.plant_id = p and not pu.paused and private.unpaid_since(pu.user_id) is not null
       and not private.no_week(pu.user_id)
       -- only after its 'deleted in 3 days' email was queued: none comes without the warning
       and exists (select 1 from public.email_queue e
                    where e.user_id = pu.user_id and e.kind = 'unpaid_last'
                      and e.created_at >= private.unpaid_since(pu.user_id))
    on conflict do nothing;
  end loop;
  return jsonb_build_object('plants', plants, 'rows', total);
end $function$;
revoke all on function private.unpaid_delete() from public, anon, authenticated;

-- api_link_status. Added: week_used on each plant.
CREATE OR REPLACE FUNCTION public.api_link_status()
 RETURNS TABLE(account_id uuid, sunsynk_username text, status text, linked_at timestamp with time zone, last_ok_at timestamp with time zone, plants jsonb, kind text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with me as (select auth.uid() u),
  b as (select me.u user_id, bl.plants_to_remove, bl.remove_on, bl.free_removals, bl.prepaid_on, bl.next_billing_date, bl.billing_day,
               coalesce(bl.comped, false) comped,
               coalesce(private.billing_drops(bl), '{}') drops,
               public.billing_room(bl.plan, bl.extra_plants) room,
               (select count(*) from public.plant_users x where x.user_id = me.u and not x.paused) act,
               (select count(*) from private.plant_picks k where k.user_id = me.u) picks,
               (select count(*) from private.plant_picks k where k.user_id = me.u and k.held) held
          from me left join private.billing bl on bl.user_id = me.u)
  select a.id, a.sunsynk_username, a.status,
         -- the share login: when this user first claimed through it
         case when a.kind = 'share' then (select min(x.linked_at) from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid())
              else a.linked_at end,
         a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                                                        'paused', pu.paused, 'linked_at', pu.linked_at,
                                                        'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                                                        'remove_on', case when pu.plant_id = any (b.plants_to_remove) then b.remove_on
                                                                          when pu.plant_id = any (b.drops) then private.billing_end_day(b.prepaid_on, b.next_billing_date, b.billing_day) end,
                                                        'drop', coalesce(pu.plant_id = any (b.drops), false),
                                                        'free_removal', coalesce(pu.plant_id = any (b.plants_to_remove) and pu.plant_id = any (b.free_removals), false),
                                                        -- gone from SunSynk: the share removed (0172), or off its login's list (0197)
                                                        'share_gone', pu.share_gone_at is not null,
                                                        'picked', k.plant_id is not null,
                                                        -- the plant's free week is over (0199): the chooser says so to an account with no plan
                                                        'week_used', exists (select 1 from private.plant_week w
                                                                              where w.plant_id = pu.plant_id and w.started_at <= now() - interval '7 days'),
                                                        -- epoch it last started collecting (0174): a plant with no reading 30 min on says so
                                                        'started_at', (select s.started_at from private.plant_alert_state s where s.plant_id = pu.plant_id),
                                                        'can_start', pu.paused and pu.share_gone_at is null
                                                                     and (b.comped or (b.act < b.room and case
                                                                           when k.plant_id is null then b.picks < b.room
                                                                           when k.held then true
                                                                           else b.held < b.room end)))
                                    order by pu.linked_at, pu.plant_id)
                     from public.plant_users pu
                     join b on b.user_id = pu.user_id
                     left join private.plant_picks k on k.user_id = pu.user_id and k.plant_id = pu.plant_id
                    where pu.account_id = a.id and pu.user_id = auth.uid()),
                  '[]'::jsonb),
         a.kind
    from private.sunsynk_accounts a
   where a.user_id = auth.uid()
      or (a.kind = 'share' and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid()))
   order by 4 desc
$function$;

notify pgrst, 'reload schema';
