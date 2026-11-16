-- ============================================================================
-- 0218 — "Your history is deleted in 3 days" only when it is (SOLAR-573).
--
-- Before (0217): unpaid_last went when a ticked plant of the account was read for
--   nobody. The delete job (0209) waits for every account with the plant ticked, so
--   the email still went, with nothing deleted, when the other account:
--     - has no plan and a later delete day (a lapsed payer next to an account whose
--       free week ended later; two accounts with no plan, the second linked later), or
--     - is in its free week or pays (already skipped in 0217).
--
-- Now: unpaid_last only when one of the account's ticked plants goes on its own
--   delete day: no other account with it ticked reads it, or has a later delete day.
--   unpaid_delete (0217) sends 'has been deleted' only after this warning, so an
--   account on a plant kept for someone else gets neither.
-- Body is 0217's otherwise.
-- ============================================================================

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
     -- 'deleted in 3 days' only when a plant of the account goes on its delete day: no other
     -- account with it ticked reads it or has a later delete day (unpaid_delete waits for all)
     and (k.kind <> 'unpaid_last'
          or exists (select 1 from public.plant_users pu
                      where pu.user_id = u.user_id and not pu.paused
                        and not exists (select 1 from public.plant_users o
                                         where o.plant_id = pu.plant_id and o.user_id <> u.user_id and not o.paused
                                           and (private.plant_live(o.user_id, o.plant_id)
                                                or private.unpaid_since(o.user_id) > u.since))))
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $function$
;
revoke all on function private.free_week_mail() from public, anon, authenticated;

notify pgrst, 'reload schema';
