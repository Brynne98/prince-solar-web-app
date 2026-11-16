-- ============================================================================
-- 0207 — the emails to an account with no plan: the plan and the offer they name,
--        and one more after the delete (SOLAR-559, decided by Brynne 2026-11-16).
--
-- Before: the day-5 and day-7 emails named Home always. An email knew the price
-- but not the offer's terms. Nothing was sent once the history was deleted.
--
-- Now:
--   - email_prices gives the offer's terms too (id, cap, months), as api_offer does.
--   - free_week_soon and the day-7 report carry the count of plants ticked, as the
--     two reminders do, so notify names Home (1 or 2) or Family (3 to 5).
--   - The reminders carry 'paid': the account had a plan, so the footer says the
--     plan ended, not the free week. Same test as api_me's wall (0204).
--   - unpaid_deleted: queued by unpaid_delete for each account with no plan that
--     runs a plant it just deleted, once per time the account lapses. Under the
--     'reminders' switch. Nothing is sent after it.
-- ============================================================================

-- 0169's email_prices, with the offer's terms.
create or replace function public.email_prices(p_user uuid)
returns jsonb language sql stable security definer set search_path = public, private, pg_temp as $$
  select jsonb_build_object('prices', private.billing_price_list(o.id), 'listPrices', private.billing_price_list(null),
           'offer', private.billing_offer_json(o.id, p_user))
    from (select private.billing_offer_now(p_user) as id) o
$$;

-- It had a plan: a charge was paid (as api_me's wall, 0204).
create or replace function private.had_plan(p_user uuid)
returns boolean language sql stable set search_path = public, private, pg_temp as $$
  select exists (select 1 from private.billing_charges c where c.user_id = p_user and c.status = 'paid')
$$;
revoke all on function private.had_plan(uuid) from public, anon, authenticated;

-- 0206's email_switch, with the email after the delete.
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
    when p_kind in ('unpaid_reminder', 'unpaid_last', 'unpaid_deleted') then 'reminders'
  end
$$;

-- ---------------------------------------------------------------------------
-- 0206's free_week_mail. Added: 'plants' on the day-5 and day-7 rows, 'paid' on
-- the two reminders. Gone from the day-5 and day-7 rows: 'days' and 'deleteOn',
-- which their emails no longer show.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 0205's unpaid_delete. Added: the email after a plant's readings went.
-- ---------------------------------------------------------------------------
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
    on conflict do nothing;
  end loop;
  return jsonb_build_object('plants', plants, 'rows', total);
end $$;
revoke all on function private.unpaid_delete() from public, anon, authenticated;

notify pgrst, 'reload schema';
