-- ============================================================================
-- 0188 — a cancel deletes on its end date; only a failed payment keeps 30 days (SOLAR-495).
--
-- Brynne 2026-11-11: a cancel to Free is the user's choice, like a downgrade (0187). On the
-- end date the plants over Free's 1 stop and are deleted, and all history before that day
-- goes: keep_until stays null, so the hourly free trim (0111, 0182) takes the account at
-- once. Keep <plan> undoes it any time before. Replaces 0146's 30 days for a cancel and
-- 0187's header ("a cancel keeps 30 days for win-back").
--
-- A failed payment's move to Free (billing_to_free, old state past_due) keeps its 30 days:
-- keep_until and remove_on as before.
--
-- Emails: bill_cancel_soon up to 3 days before the end date (billing_run), and the winback
-- email on the day (0144) without a delete date. Its days are counted when queued, before
-- the trim, as the free week's report does (0182).
-- ============================================================================

-- 0146's keep_until: a failed payment only.
create or replace function private.billing_keep_until()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  if new.plan <> 'free' then
    new.keep_until := null;
  elsif old.plan in ('home', 'family') and not old.comped then
    new.keep_until := case when old.state = 'past_due' then private.billing_today() + 30 end;
  end if;
  return new;
end $$;
revoke all on function private.billing_keep_until() from public, anon, authenticated;

-- 0144's winback: no keepUntil; days of history at the plant Free keeps (the pick, else the
-- first linked, as billing_renew orders it), counted before the trim.
create or replace function private.billing_winback()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (new.user_id, 'winback', 'winback:' || old.next_billing_date,
          jsonb_build_object('from', old.plan,
            'days', (select count(*) from public.plant_energy e
                      where e.bucket = 'day'
                        and e.plant_id = (select pu.plant_id from public.plant_users pu
                                           where pu.user_id = new.user_id and not pu.paused
                                             and pu.plant_id <> all (coalesce(old.plants_to_remove, '{}'))
                                           order by array_position(old.next_keep, pu.plant_id) nulls last, pu.linked_at, pu.plant_id
                                           limit 1))), 1)
  on conflict do nothing;
  return null;
end $$;
revoke all on function private.billing_winback() from public, anon, authenticated;

-- 0187's renewal: a cancel's stopped plants go on the day too.
create or replace function public.billing_renew(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  due int;
  v_plan text; v_period text;
  going bigint[];
  keep bigint[];
  before bigint[];
  stopped bigint[];
  p bigint;
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' or b.comped then
    raise exception 'nothing to renew on Free' using errcode = '22023';
  end if;
  -- a switch paid this date's year already (0138)
  due := case when b.prepaid_on = b.next_billing_date then 0 else public.billing_amount_due(p_user) end;
  -- A cancel booked in a paid year (SOLAR-457): the year starts as paid; the cancel waits for its end.
  if b.prepaid_on = b.next_billing_date and b.next_plan = 'free' then
    update private.billing
       set period = 'yearly',
           next_billing_date = public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1),
           extra_plants = case when b.plan = 'family' then coalesce(b.next_extra_plants, b.extra_plants) else 0 end,
           next_period = null, next_extra_plants = null, prepaid_on = null, updated_at = now()
     where user_id = p_user;
    return jsonb_build_object('charge', 0, 'plan', b.plan, 'removePlants', '[]'::jsonb, 'stopped', '[]'::jsonb);
  end if;
  v_plan := coalesce(b.next_plan, b.plan);
  v_period := coalesce(b.next_period, b.period);
  going := case when b.remove_on <= b.next_billing_date then b.plants_to_remove else '{}' end;
  -- the plants the booked plan keeps: those that do not stop (0136)
  select coalesce(array_agg(plant_id order by array_position(b.next_keep, plant_id) nulls last, linked_at, plant_id), '{}')
    into keep from public.plant_users
   where user_id = p_user and not paused and plant_id <> all (coalesce(b.plants_to_remove, '{}'))
     and plant_id <> all (private.billing_drops(b));
  select coalesce(array_agg(plant_id), '{}') into before from public.plant_users where user_id = p_user and not paused;
  update private.billing
     set plan = v_plan,
         period = case when v_plan = 'free' then null else v_period end,
         billing_day = case when v_plan = 'free' then null else b.billing_day end,
         next_billing_date = case when v_plan = 'free' then null
                             else public.billing_step(b.next_billing_date, v_period, b.billing_day, 1) end,
         extra_plants = case when v_plan = 'family' then coalesce(b.next_extra_plants, b.extra_plants) else 0 end,
         next_plan = null, next_period = null, next_extra_plants = null, next_keep = '{}', prepaid_on = null,
         updated_at = now()
   where user_id = p_user;
  -- booked for deletion last, then the pick
  perform private.billing_fit(p_user, coalesce(b.plants_to_remove, '{}'), keep);
  select coalesce(array_agg(plant_id order by plant_id), '{}') into stopped from public.plant_users
   where user_id = p_user and paused and plant_id = any (before) and plant_id <> all (coalesce(b.plants_to_remove, '{}'));
  -- stopped by the change: deleted on the day, on Free too (SOLAR-495)
  if cardinality(stopped) > 0 then
    -- removals due today (Remove login) go now, so the new date does not put them off
    if cardinality(going) > 0 then
      foreach p in array (select array_agg(x order by x) from unnest(going) x) loop
        perform private.billing_drop_plant(p_user, p);
      end loop;
      update private.billing
         set plants_to_remove = array(select x from unnest(plants_to_remove) x where x <> all (going)),
             free_removals = array(select x from unnest(free_removals) x where x <> all (going))
       where user_id = p_user;
    end if;
    -- a plan the user chose (a cancel or a smaller plan): its stopped plants go today (SOLAR-492, SOLAR-495)
    foreach p in array stopped loop
      perform private.billing_drop_plant(p_user, p);
    end loop;
  end if;
  return jsonb_build_object('charge', due, 'plan', v_plan, 'removePlants', to_jsonb(going), 'stopped', to_jsonb(stopped));
end $$;

-- 0187's api_link_status: a cancel's drop is dated the end date, not 30 days on.
create or replace function public.api_link_status()
 returns table(account_id uuid, sunsynk_username text, status text, linked_at timestamptz, last_ok_at timestamptz, plants jsonb, kind text)
 language sql
 security definer
 set search_path to 'public', 'private', 'pg_temp'
as $function$
  with b as (select bl.*, private.billing_drops(bl) drops from private.billing bl where bl.user_id = auth.uid())
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
                                                        'free_removal', pu.plant_id = any (b.plants_to_remove) and pu.plant_id = any (b.free_removals),
                                                        -- the owner removed the share in SunSynk (0172)
                                                        'share_gone', pu.share_gone_at is not null)
                                    order by pu.linked_at, pu.plant_id)
                     from public.plant_users pu
                     left join b on b.user_id = pu.user_id
                    where pu.account_id = a.id and pu.user_id = auth.uid()),
                  '[]'::jsonb),
         a.kind
    from private.sunsynk_accounts a
   where a.user_id = auth.uid()
      or (a.kind = 'share' and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid()))
   order by 4 desc
$function$;

-- 0187's api_billing_change: the cancel email's delete date, the same way.
create or replace function public.api_billing_change(p_plan text, p_period text default null, p_keep bigint[] default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing; was_booked boolean; was_cancel boolean; drops bigint[];
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  -- for update: a double tap undoes once and emails once; a second cancel is not emailed again
  select next_plan is not null or (next_period is not null and prepaid_on is null), next_plan is not distinct from 'free'
    into was_booked, was_cancel
    from private.billing where user_id = auth.uid() for update;
  perform public.billing_book_change(auth.uid(), p_plan, p_period, p_keep);
  select * into b from private.billing where user_id = auth.uid();
  drops := private.billing_drops(b);
  if was_cancel and b.next_plan = 'free' then
    null;
  elsif b.next_plan is not null or (b.next_period is not null and b.prepaid_on is null) then
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (auth.uid(), 'bill_change', 'bill_change:' || gen_random_uuid(),
            jsonb_build_object('from', b.plan, 'to', coalesce(b.next_plan, b.plan),
              'fromPeriod', b.period, 'toPeriod', coalesce(b.next_period, b.period),
              -- a cancel in a paid year ends when that year does (SOLAR-457)
              'on', case when b.prepaid_on is not null then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                         else b.next_billing_date end,
              'nextAmount', case when coalesce(b.next_plan, b.plan) <> 'free' then public.billing_amount_due(auth.uid()) end,
              'deleteOn', case when cardinality(drops) > 0 then private.billing_end_day(b.prepaid_on, b.next_billing_date, b.billing_day) end,
              'removePlants', coalesce((select jsonb_agg(pu.plant_name order by pu.linked_at) from public.plant_users pu
                                         where pu.user_id = auth.uid() and pu.plant_id = any (drops)), '[]'::jsonb)),
            1);
  elsif was_booked then
    -- in a paid year the next payment is the year after the paid one (SOLAR-467)
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (auth.uid(), 'bill_kept', 'bill_kept:' || gen_random_uuid(),
            jsonb_build_object('plan', b.plan, 'period', coalesce(b.next_period, b.period),
              'on', case when b.prepaid_on is not null then public.billing_step(b.next_billing_date, 'yearly', b.billing_day, 1)
                         else b.next_billing_date end,
              'nextAmount', public.billing_amount_due(auth.uid())),
            1);
  end if;
  return public.api_billing_status();
end $$;

-- 0170's daily run, with the cancel's 3-day email.
create or replace function public.billing_run(p_today date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $$
declare
  today date := coalesce(p_today, private.billing_today());
  b private.billing;
  r jsonb;
  c private.billing_charges;
  ref text;
  out jsonb := '[]'::jsonb;
  p bigint;
  s int;
begin
  -- Links wait for the run (0170). Before the run's own lock: a run queued behind a
  -- link holds nothing. A transaction already holding a link's share (a test that
  -- links, then runs) keeps it: asking for the whole lock would wait on itself.
  if not exists (select 1 from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()
                    and classid = 3 and objid = 0 and objsubid = 2 and granted) then
    perform pg_advisory_xact_lock(3, 0);
  end if;
  perform pg_advisory_xact_lock(hashtext('billing_run'));

  -- Lost disputes owed, on a quiet day (0132). First, before this call holds any user
  -- lock: they lock charge rows before the user, as a dispute event does.
  for b in select bl.* from private.billing bl
            where exists (select 1 from private.billing_charges x where x.user_id = bl.user_id and x.dispute_owed)
            order by bl.user_id loop
    perform private.billing_dispute_apply(b.user_id, today);
  end loop;

  -- A renewal handed out and not reported: handed out again with its reference.
  for c in select * from private.billing_charges
            where kind = 'renewal' and status = 'pending'
              and (claimed_at is null or claimed_at < now() - interval '10 minutes' or created_on < today)
            order by created_at, reference loop
    select * into b from private.billing where user_id = c.user_id;
    if private.billing_charge_stale(c, b) is not null then
      update private.billing_charges set status = 'failed', error = 'not charged: no longer due', settled_at = now()
       where reference = c.reference;
      continue;
    end if;
    -- Expired before its day is counted (0132), so today still gets its retry.
    if c.tried_on <= today - 3 then
      perform public.billing_charge_failed(c.reference, 'not settled at Paystack 3 days after the first try');
      continue;
    end if;
    -- handed_from: the day it was last handed out, given back if this call never starts it (0132)
    update private.billing_charges set handed_from = case when created_on < today then created_on else handed_from end,
           created_on = greatest(created_on, today) where reference = c.reference;
    out := out || jsonb_build_object('reference', c.reference, 'amount', c.amount, 'card', b.card->>'authorization_code',
                                     'email', coalesce(b.card_email, (select email from auth.users where id = c.user_id)));
  end loop;

  -- Free from day 8, once all four tries are made and none is open.
  for b in select * from private.billing bl
            where state = 'past_due' and today - past_due_since >= 8
              and not exists (select 1 from private.billing_charges x
                               where x.user_id = bl.user_id and x.kind = 'renewal' and x.status = 'pending') loop
    -- no failed renewal to retry counts as the tries made (0168)
    if private.billing_try_slot(b.user_id, b.past_due_since) is null
       or not exists (select 1 from private.billing_charges x where x.user_id = b.user_id and x.kind = 'renewal'
                       and x.due_on = b.past_due_since) then
      perform private.billing_to_free(b.user_id, today);
    end if;
  end loop;

  -- Retries: the next of day 1, 3 and 7 once its day has come; one a day, none while one is open.
  for b in select * from private.billing bl
            where state = 'past_due'
              and not exists (select 1 from private.billing_charges x
                               where x.user_id = bl.user_id and x.kind = 'renewal'
                                 and (x.created_on = today or x.status = 'pending')) loop
    s := private.billing_try_slot(b.user_id, b.past_due_since);
    continue when s is null or today - b.past_due_since < s;
    select * into c from private.billing_charges
     where user_id = b.user_id and kind = 'renewal' and due_on = b.past_due_since order by created_at limit 1;
    continue when not found;  -- nothing to retry (0168)
    ref := 'psh_' || replace(gen_random_uuid()::text, '-', '');
    insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on)
    values (ref, b.user_id, 'renewal', c.plan, c.period, c.amount, c.due_on, today);
    out := out || jsonb_build_object('reference', ref, 'amount', c.amount, 'card', b.card->>'authorization_code',
                                     'email', coalesce(b.card_email, (select email from auth.users where id = b.user_id)));
  end loop;

  -- Billing dates.
  for b in select * from private.billing
            where plan <> 'free' and not comped and state = 'active' and next_billing_date <= today loop
    r := public.billing_renew(b.user_id);
    if (r->>'plan') <> 'free' and (r->>'charge')::int > 0 then
      ref := 'psh_' || replace(gen_random_uuid()::text, '-', '');
      insert into private.billing_charges (reference, user_id, kind, plan, period, amount, due_on, created_on)
      select ref, b.user_id, 'renewal', bl.plan, bl.period, (r->>'charge')::int, b.next_billing_date, today
        from private.billing bl where bl.user_id = b.user_id;
      out := out || jsonb_build_object('reference', ref, 'amount', (r->>'charge')::int, 'card', b.card->>'authorization_code',
                                       'email', coalesce(b.card_email, (select email from auth.users where id = b.user_id)));
    end if;
  end loop;

  -- No saved card: fails now (the user gets the "pay with another card" email).
  for r in select x from jsonb_array_elements(out) x where x->>'card' is null loop
    perform public.billing_charge_failed(r->>'reference', 'no saved card');
  end loop;
  out := coalesce((select jsonb_agg(x) from jsonb_array_elements(out) x where x->>'card' is not null), '[]'::jsonb);
  update private.billing_charges set claimed_at = now(), tried_on = coalesce(tried_on, today)
   where reference in (select x->>'reference' from jsonb_array_elements(out) x);

  -- Booked removals due today, or missed. The user lock and the list read again (0132):
  -- a plant started meanwhile is off the list, and the lock order is a payment's.
  for b in select * from private.billing where remove_on <= today and cardinality(plants_to_remove) > 0 loop
    perform private.billing_lock(b.user_id);
    select * into b from private.billing where user_id = b.user_id for update;
    continue when b.remove_on is null or b.remove_on > today;
    foreach p in array (select array_agg(x order by x) from unnest(b.plants_to_remove) x) loop
      perform private.billing_drop_plant(b.user_id, p);
    end loop;
    update private.billing set plants_to_remove = '{}', remove_on = null, free_removals = '{}', updated_at = now()
     where user_id = b.user_id;
  end loop;

  -- Card pages left unpaid 2 days: closed (0132). A late payment still applies or is refunded.
  update private.billing_charges set status = 'failed', error = 'card page not finished', settled_at = now()
   where status = 'pending' and kind in ('start', 'upgrade', 'settle', 'card') and created_at < now() - interval '2 days';

  -- Up to 3 days before a removal, once.
  insert into public.email_queue (user_id, kind, key, data, priority)
  select bl.user_id, 'bill_removal_soon', 'bill_removal_soon:' || bl.remove_on,
         jsonb_build_object('on', bl.remove_on,
           'plants', (select jsonb_agg(pu.plant_name order by pu.linked_at) from public.plant_users pu
                       where pu.user_id = bl.user_id and pu.plant_id = any (bl.plants_to_remove))), 1
    from private.billing bl
   where bl.remove_on > today and bl.remove_on <= today + 3 and cardinality(bl.plants_to_remove) > 0
  on conflict do nothing;

  -- A cancel the user chose, up to 3 days before its end date, once (SOLAR-495): history
  -- and stopped plants are deleted that day. Comped accounts have no cancel to warn of.
  insert into public.email_queue (user_id, kind, key, data, priority)
  select x.user_id, 'bill_cancel_soon', 'bill_cancel_soon:' || x.ends,
         jsonb_build_object('from', x.plan, 'on', x.ends), 1
    from (select bl.user_id, bl.plan, private.billing_end_day(bl.prepaid_on, bl.next_billing_date, bl.billing_day) ends
            from private.billing bl
           where bl.plan in ('home', 'family') and not bl.comped and bl.state = 'active' and bl.next_plan = 'free') x
   where x.ends > today and x.ends <= today + 3
  on conflict do nothing;

  -- Yearly plans, up to 60 days before the date, once.
  insert into public.email_queue (user_id, kind, key, data, priority)
  select bl.user_id, 'bill_renewal_notice', 'bill_renewal_notice:' || bl.next_billing_date,
         jsonb_build_object('plan', coalesce(bl.next_plan, bl.plan), 'on', bl.next_billing_date,
           'amount', public.billing_amount_due(bl.user_id),
           'changed', bl.next_plan is not null or bl.next_period is not null), 1
    from private.billing bl
   where bl.period = 'yearly' and not bl.comped and bl.state = 'active'
     and bl.next_billing_date > today and bl.next_billing_date <= today + 60
     and coalesce(bl.next_plan, bl.plan) <> 'free' and coalesce(bl.next_period, bl.period) = 'yearly'
  on conflict do nothing;

  return out;
end $$;

notify pgrst, 'reload schema';
