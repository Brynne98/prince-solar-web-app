-- ============================================================================
-- 0215 — one rule for when an account's free week ends; paying uses it up; no login
--        swap inside the week (SOLAR-568, decided by Brynne 2026-11-16).
--
-- Before:
--   - Each reader added 7 days to free_week_logins.started_at itself. A week that
--     was over at the start (the account came to a plant whose week was used) was
--     marked by dating started_at 15 days back (0200, 0203); a week borrowed from a
--     plant's open week took that plant's start date (0208). The real date was lost.
--   - (a) An account that paid before its first plant got a week dated at the link.
--     A plan that ended within 7 days of that left the week "running": no pay
--     screen, every plant locked, and the day-5 free-week email and bell notice.
--   - (b) In its week, an account with no plan could remove its login and link one
--     whose plants all had their week: every plant locked, no pay screen.
--
-- Now:
--   - started_at is the real day the account's week row was written.
--   - over_at / over_why: the week ended early. 'plan': the account paid or got a
--     plan (at the link, or when the plan starts). 'plant': its plants' weeks were
--     used before it came (over_at at the arrival) or end sooner (that plant's end).
--   - private.week_ends: least(started_at + 7 days, over_at). Every reader goes by
--     it: plant_in_week, unpaid_since, no_week, api_me, free_week_mail,
--     billing_notices, week_start, link_login_allowed.
--   - link_login_allowed: in the week, with no plan, only the login the week started
--     on (the shared-plant login does not count).
--   - Rows already written: the 15-days-back rows written since 0209 get their real
--     date back (written_at); borrowed rows likewise; paid accounts get over_at at
--     their first payment. Rows from before 0209 have no real date stored and stay.
-- ============================================================================

alter table private.free_week_logins
  add column if not exists over_at timestamptz,
  add column if not exists over_why text check (over_why in ('plan', 'plant'));

-- ---------------------------------------------------------------------------
-- The rule. Null: the account has no week row.
-- ---------------------------------------------------------------------------
create or replace function private.week_ends(p_user uuid)
returns timestamptz language sql stable set search_path = public, private, pg_temp as $$
  select min(least(f.started_at + interval '7 days', f.over_at))
    from private.free_week_logins f where f.user_id = p_user
$$;
revoke all on function private.week_ends(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Rows already written.
-- ---------------------------------------------------------------------------
-- Week over at the arrival, dated back (0203/0208): the real date is written_at.
update private.free_week_logins
   set started_at = written_at, over_at = written_at, over_why = 'plant'
 where written_at >= started_at + interval '7 days'
   -- as 0203/0208 dated it, not a comp set-back's row (billing_set_comped: the first link)
   and (started_at = written_at - interval '15 days'
        or started_at = (select min(w.started_at) from private.plant_week w
                           join public.plant_users pu on pu.plant_id = w.plant_id
                          where pu.user_id = free_week_logins.user_id));

-- Week borrowed from a plant's open week (0208): the real date is written_at, the end the plant's.
update private.free_week_logins f
   set started_at = f.written_at, over_at = f.started_at + interval '7 days', over_why = 'plant'
 where f.over_why is null
   and f.written_at > f.started_at + interval '1 minute'
   and f.written_at < f.started_at + interval '7 days'
   and exists (select 1 from private.plant_week w join public.plant_users pu on pu.plant_id = w.plant_id
                where pu.user_id = f.user_id and w.started_at = f.started_at);

-- Paid inside the week, or before it: the week ended at the first payment.
update private.free_week_logins f
   set over_at = greatest(f.started_at, p.at), over_why = 'plan'
  from (select c.user_id, min(coalesce(c.settled_at, c.created_at)) as at
          from private.billing_charges c where c.status = 'paid' group by c.user_id) p
 where p.user_id = f.user_id
   and p.at < least(f.started_at + interval '7 days', coalesce(f.over_at, 'infinity'));

-- A plan with no payment (comped) while the week runs: ended now.
update private.free_week_logins f
   set over_at = now(), over_why = 'plan'
  from private.billing b
 where b.user_id = f.user_id and b.plan <> 'free'
   and least(f.started_at + interval '7 days', coalesce(f.over_at, 'infinity')) > now();

-- ---------------------------------------------------------------------------
-- The account's week row, for plants of p_plants that run for this account now.
-- 0208's rule with true dates. The caller holds the user lock and the plants' locks.
-- ---------------------------------------------------------------------------
create or replace function private.week_start(p_user uuid, p_plants bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  run bigint[] := array(select pu.plant_id from public.plant_users pu
                         where pu.user_id = p_user and pu.plant_id = any (p_plants) and not pu.paused);
  v_plan text := coalesce((select b.plan from private.billing b where b.user_id = p_user), 'free');
  paid boolean := v_plan <> 'free' or private.had_plan(p_user);
begin
  if cardinality(run) = 0 then return; end if;
  if v_plan = 'free' and coalesce(private.week_ends(p_user) > now(), true) then
    insert into private.plant_week (plant_id) select x from unnest(run) x
    on conflict (plant_id) do nothing;
  end if;
  insert into private.free_week_logins (sunsynk_username, user_id, started_at, over_at, over_why)
  select lower(coalesce((select a.sunsynk_username from public.plant_users pu
                           join private.sunsynk_accounts a on a.id = pu.account_id
                          where pu.user_id = p_user and pu.plant_id = run[1]), '')),
         p_user, now(), e.at, e.why
    from (select case when paid then now()
                      when w.open is null then now()
                      when w.open < now() then w.open + interval '7 days' end as at,
                 case when paid then 'plan'
                      when w.open is null or w.open < now() then 'plant' end as why
            from (select max(started_at) filter (where started_at > now() - interval '7 days') as open
                    from private.plant_week where plant_id = any (run)) w) e
  on conflict (user_id) do nothing;
end $$;
revoke all on function private.week_start(uuid, bigint[]) from public, anon, authenticated;

-- A plan starts: a week still running ends now.
create or replace function private.billing_week_used()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  update private.free_week_logins set over_at = now(), over_why = 'plan'
   where user_id = new.user_id and private.week_ends(new.user_id) > now();
  return null;
end $$;
revoke all on function private.billing_week_used() from public, anon, authenticated;

drop trigger if exists billing_week_used on private.billing;
create trigger billing_week_used after insert or update of plan on private.billing
  for each row when (new.plan <> 'free')
  execute function private.billing_week_used();

-- 0204's plant_in_week, by the rule.
create or replace function private.plant_in_week(p_user uuid, p_plant bigint)
returns boolean
language sql stable set search_path = public, private, pg_temp
as $$
  select coalesce(private.week_ends(p_user) > now(), false)
     and exists (select 1 from private.plant_week w
                  where w.plant_id = p_plant and w.started_at > now() - interval '7 days')
$$;
revoke all on function private.plant_in_week(uuid, bigint) from public, anon, authenticated;

-- 0212's unpaid_since, by the rule.
create or replace function private.unpaid_since(p_user uuid)
returns timestamptz
language sql stable set search_path = public, private, pg_temp
as $$
  select case when coalesce(b.plan, 'free') = 'free'
              then greatest(private.week_ends(p_user), b.ended_at) end
    from (select p_user as u) x
    left join private.billing b on b.user_id = x.u
$$;
revoke all on function private.unpaid_since(uuid) from public, anon, authenticated;

-- 0209's no_week: its plants' weeks were used before it came, and it never paid.
create or replace function private.no_week(p_user uuid)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select exists (select 1 from private.free_week_logins f
                  where f.user_id = p_user and f.over_why = 'plant' and f.over_at <= f.started_at)
     and not private.had_plan(p_user)
$$;
revoke all on function private.no_week(uuid) from public, anon, authenticated;

-- 0203's link_login_allowed. Added: in the free week, only the week's own login.
create or replace function public.link_login_allowed(p_user uuid, p_username text)
returns boolean
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select coalesce((select b.plan from private.billing b where b.user_id = p_user), 'free') <> 'free'
      or (not exists (select 1 from private.sunsynk_accounts a
                       where a.user_id = p_user and a.kind = 'login' and lower(a.sunsynk_username) <> lower(p_username))
          and not exists (select 1 from private.free_week_logins f
                           where f.user_id = p_user and private.week_ends(p_user) > now()
                             and f.sunsynk_username not in ('', lower(p_username))
                             and f.sunsynk_username not in (select lower(s.sunsynk_username) from private.sunsynk_accounts s
                                                             where s.kind = 'share')))
$$;
revoke all on function public.link_login_allowed(uuid, text) from public, anon, authenticated;
grant execute on function public.link_login_allowed(uuid, text) to service_role;

-- 0209's api_me. freeWeekEndsAt by the rule.
CREATE OR REPLACE FUNCTION public.api_me()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'user', jsonb_build_object('id', auth.uid()),
    'plan', coalesce((select plan from private.billing where user_id = auth.uid()), 'free'),
    'freeWeekEndsAt', (select private.week_ends(auth.uid())
                        where coalesce((select plan from private.billing where user_id = auth.uid()), 'free') = 'free'),
    -- no plan, the free week over, and not in a failed card's 30 days: the pay screen
    'wall', (select jsonb_build_object(
                      'plants', (select count(*) from private.plant_picks k where k.user_id = auth.uid()),
                      'deleteAt', u.since + interval '30 days',
                      -- its plant's week was over before it came: it never had one
                      'noWeek', private.no_week(auth.uid()),
                      -- it had a plan: the screen says the plan ended, not the free week
                      'paid', exists (select 1 from private.billing_charges c
                                       where c.user_id = auth.uid() and c.status = 'paid'))
               from (select private.unpaid_since(auth.uid()) as since) u
              where u.since <= now()
                and not exists (select 1 from private.billing b
                                 where b.user_id = auth.uid() and b.keep_until >= private.billing_today())),
    'prefs', coalesce((select prefs from public.profiles where user_id = auth.uid()), '{}'::jsonb),
    'plants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pu.plant_id, 'name', pu.plant_name, 'linkedAt', pu.linked_at,
               'config', to_jsonb(c) - 'plant_id' - 'updated_by')
             order by pu.linked_at, pu.plant_id)
        from public.plant_users pu
        left join public.plant_config c on c.plant_id = pu.plant_id
       where pu.user_id = auth.uid() and pu.plant_id in (select public.my_plant_ids())), '[]'::jsonb))
$function$
;
revoke all on function public.api_me() from public, anon;
grant execute on function public.api_me() to authenticated, service_role;

-- 0212's free_week_mail. Day 5 and day 7 by the week's end; none for a week ended at the start or by a plan.
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
    -- Day 2 after the account's first plant, on any plan; Hide on the app's card doesn't stop it.
    select fp.user_id, fp.plant_id, private.setup_steps_open(fp.plant_id) as steps,
           c.has_battery is distinct from false as battery
      from first_plant fp left join public.plant_config c on c.plant_id = fp.plant_id
     where now() >= fp.linked_at + interval '2 days' and now() < fp.linked_at + interval '3 days'
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
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $function$
;
revoke all on function private.free_week_mail() from public, anon, authenticated;

-- 0205's billing_notices. The day-5 notice by the week's end.
CREATE OR REPLACE FUNCTION private.billing_notices()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  me uuid := auth.uid();
  b private.billing;
  today date := private.billing_today();
  st jsonb;
  week_end timestamptz;
  first_plant bigint;
  out jsonb := '[]';
  booked boolean;
begin
  select * into b from private.billing where user_id = me;
  booked := b.next_plan is not null or b.next_period is not null or b.next_extra_plants is not null;

  if b.state = 'past_due' and b.plan <> 'free' then
    -- the same next try and Free date as Billing shows
    st := public.api_billing_status();
    out := out || jsonb_build_object('kind', 'bill_failed', 'plan', b.plan, 'amount', st->'nextAmount',
                                     'nextTry', st->'nextTry', 'freeOn', st->'freeOn');
  end if;

  if b.remove_on > today and b.remove_on <= today + 3 and cardinality(b.plants_to_remove) > 0 then
    -- room: the plants the plan covers from that date (a booked change, else today's plan)
    out := out || jsonb_build_object('kind', 'bill_removal_soon', 'on', b.remove_on,
      'room', coalesce(private.billing_next_room(b), public.billing_room(b.plan, b.extra_plants)),
      'plants', coalesce((select jsonb_agg(coalesce(pu.plant_name, 'Plant ' || pu.plant_id) order by pu.linked_at)
                   from plant_users pu where pu.user_id = me and pu.plant_id = any (b.plants_to_remove)), '[]'));
  end if;

  -- a paid switch to yearly (prepaid_on, 0138) has nothing to undo; a cancel in it does (SOLAR-467)
  if b.plan <> 'free' and not b.comped and b.state = 'active' and booked
     and (b.prepaid_on is null or b.next_plan = 'free') then
    out := out || jsonb_build_object('kind', 'bill_change',
      'on', case when b.prepaid_on is not null then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                 else b.next_billing_date end,
      'plan', b.plan, 'period', b.period, 'nextPlan', b.next_plan, 'nextPeriod', b.next_period,
      'extraPlants', coalesce(b.extra_plants, 0), 'nextExtraPlants', b.next_extra_plants);
  end if;

  if b.period = 'yearly' and not b.comped and b.state = 'active' and not booked
     and b.next_billing_date > today and b.next_billing_date <= today + 60 then
    out := out || jsonb_build_object('kind', 'bill_renewal_notice', 'plan', b.plan, 'on', b.next_billing_date,
                                     'amount', public.billing_amount_due(me));
  end if;

  -- the free week: never paid, as free_week_mail (0145) reads it
  if coalesce(b.plan, 'free') = 'free' and not coalesce(b.comped, false) and b.keep_until is null then
    select private.week_ends(me) into week_end from private.free_week_logins f
     where f.user_id = me and f.over_why is distinct from 'plan';
    if now() >= week_end - interval '2 days' and now() < week_end then
      select pu.plant_id into first_plant from plant_users pu where pu.user_id = me and not pu.paused
       order by pu.linked_at, pu.plant_id limit 1;
      out := out || jsonb_build_object('kind', 'free_week_soon',
        'endsAt', week_end,
        'plant', (select coalesce(pu.plant_name, 'Plant ' || pu.plant_id) from plant_users pu
                   where pu.user_id = me and pu.plant_id = first_plant),
        'days', (select count(*) from plant_energy e
                  where e.plant_id = first_plant and e.bucket = 'day'
                    and e.period < public.today_tz(public.plant_tz(first_plant))),
        'perMonth', (private.billing_price_list(private.billing_offer_now(me)) #>> '{monthly,home}')::int,
        'list', (private.billing_price_list(null) #>> '{monthly,home}')::int);
    end if;
  end if;

  return out;
end $function$
;
revoke all on function private.billing_notices() from public, anon, authenticated;

notify pgrst, 'reload schema';
