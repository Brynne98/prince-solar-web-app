-- ============================================================================
-- 0209 — an account that never had a free week is not told it ended (SOLAR-566).
--
-- Before: a new account whose plant's week was already over (another account used
-- it) got a free_week_logins row dated at least 15 days back (0203). It read nothing,
-- but its pay screen said "Your free week has ended", and the day-21, day-34 and
-- day-37 emails told it readings stopped on a date before it signed up.
--
-- Now:
--   - free_week_logins.written_at: when the row was written. Rows from before this
--     migration keep null and count as a week had.
--   - private.no_week: the row was written after its week was over, and the account
--     never paid.
--   - api_me's wall carries noWeek; the pay screen's title says the plant has had
--     its free week.
--   - free_week_mail and unpaid_delete queue no unpaid email for such an account.
-- ============================================================================

alter table private.free_week_logins add column if not exists written_at timestamptz;
alter table private.free_week_logins alter column written_at set default now();

create or replace function private.no_week(p_user uuid)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select exists (select 1 from private.free_week_logins f
                  where f.user_id = p_user and f.written_at >= f.started_at + interval '7 days')
     and not private.had_plan(p_user)
$$;
revoke all on function private.no_week(uuid) from public, anon, authenticated;

-- 0204's api_me. Added: noWeek on the wall.
create or replace function public.api_me()
returns jsonb
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  select jsonb_build_object(
    'user', jsonb_build_object('id', auth.uid()),
    'plan', coalesce((select plan from private.billing where user_id = auth.uid()), 'free'),
    'freeWeekEndsAt', (select min(f.started_at) + interval '7 days' from private.free_week_logins f
                        where f.user_id = auth.uid()
                          and coalesce((select plan from private.billing where user_id = auth.uid()), 'free') = 'free'),
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
$$;
revoke all on function public.api_me() from public, anon;
grant execute on function public.api_me() to authenticated, service_role;

-- 0207's free_week_mail. Added: no unpaid email to an account that never had a week.
create or replace function private.free_week_mail()
returns int language plpgsql security definer set search_path = public, private, pg_temp as $$
declare n int;
begin
  with fw as (
    select f.user_id, min(f.started_at) as started
      from private.free_week_logins f
      left join private.billing b on b.user_id = f.user_id
     where coalesce(b.plan, 'free') = 'free'
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
      from private.free_week_logins f
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
         jsonb_build_object('endsAt', extract(epoch from fw.started + interval '7 days')::bigint,
           'plants', (select count(*) from private.plant_picks p where p.user_id = fw.user_id),
           'perMonth', round(public.billing_amount('home', 'yearly', 0,
                         private.billing_offer_open(fw.user_id, private.billing_today())) / 12.0)::int), 1
    from fw left join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '5 days' and now() < fw.started + interval '6 days'
  union all
  select fw.user_id, fp.plant_id, 'report_week', 'report_week:free:' || fw.user_id,
         jsonb_build_object('today', timezone(public.plant_tz(fp.plant_id), now())::date, 'freeWeekEnds', true,
           'plants', (select count(*) from private.plant_picks p where p.user_id = fw.user_id),
           'from', timezone(public.plant_tz(fp.plant_id), fw.started)::date), 2
    from fw join first_plant fp on fp.user_id = fw.user_id
   where now() >= fw.started + interval '7 days' and now() < fw.started + interval '8 days'
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
end $$;
revoke all on function private.free_week_mail() from public, anon, authenticated;

-- 0207's unpaid_delete. Added: no day-37 email to an account that never had a week.
create or replace function private.unpaid_delete()
returns jsonb
language plpgsql security definer set search_path = public, private, pg_temp
as $$
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
    on conflict do nothing;
  end loop;
  return jsonb_build_object('plants', plants, 'rows', total);
end $$;
revoke all on function private.unpaid_delete() from public, anon, authenticated;

notify pgrst, 'reload schema';
