-- ============================================================================
-- 0170: a link during the daily billing run waits for it (SOLAR-438).
--
-- billing_run handles every due account in one transaction. Its plant locks
-- build up account by account, so they are not in plant id order. A link
-- (plant_users_upsert) takes its plants in id order. Run holds plant 5001 and
-- waits for 3001; the link holds 3001 and waits for 5001: deadlock, and either
-- the link answers 502 or the whole run rolls back.
--
-- Lock (3, 0): billing_run takes it whole, first. A link and a login removal
-- take it shared, before any other lock. So a link either ends before the run
-- starts or waits for the run holding nothing. The run is short (no Paystack
-- calls in it), so a link waits under a second.
--
-- Not covered: paths that lock charge rows before the user (payments,
-- disputes, account delete) keep their order; giving them the barrier would
-- make a webhook wait on the run while holding a row the run wants.
-- ============================================================================

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

create or replace function public.plant_users_upsert(p_user uuid, p_account uuid, p_rows jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $$
declare p bigint;
begin
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (0170)
  perform private.billing_lock(p_user);
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for p in select distinct (r->>'plant_id')::bigint from jsonb_array_elements(p_rows) r order by 1 loop
    perform pg_advisory_xact_lock(p);
  end loop;
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and status <> 'disabled') then
    raise exception 'plant_users_upsert: account % is removed or disabled', p_account;
  end if;
  for p in
    select g.plant_id from private.plant_purge g
     where g.plant_id in (select (r->>'plant_id')::bigint from jsonb_array_elements(p_rows) r)
     order by g.plant_id
  loop
    raise notice 'plant % relinked while waiting to be purged: wiping first (%)', p, private.purge_plant(p);
  end loop;

  insert into public.plant_users (plant_id, user_id, account_id, plant_name)
  select (r->>'plant_id')::bigint, p_user, p_account, r->>'plant_name'
    from jsonb_array_elements(p_rows) r
  on conflict (plant_id, user_id) do update
    set account_id = excluded.account_id, plant_name = excluded.plant_name;

  insert into public.app_config (key, value, note)
  select 'CALIBRATION_PLANT', (r->>'plant_id')::bigint,
         'the one plant the single-site forecast/alerts are bound to; set by the first link, then fixed'
    from jsonb_array_elements(p_rows) r
   order by (r->>'plant_id')::bigint
   limit 1
  on conflict (key) do nothing;
end $$;

create or replace function public.api_link_disconnect(p_account uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'vault', 'pg_temp'
AS $$
declare
  uid uuid := auth.uid();
  p bigint;
  mine bigint[];
  gone bigint[];
  orphans bigint[];
  sid uuid;
begin
  if uid is null or not exists (select 1 from private.sunsynk_accounts where id = p_account and user_id = uid) then
    raise exception 'not your account';
  end if;

  -- account lock, then its plants ascending: the order every path uses. Holding
  -- the account lock means its hourly sync cannot add a plant under us.
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (0170)
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  select coalesce(array_agg(plant_id order by plant_id), '{}') into mine
    from public.plant_users where account_id = p_account and user_id = uid;
  foreach p in array mine loop perform pg_advisory_xact_lock(p); end loop;

  with d as (
    delete from public.plant_users where account_id = p_account and user_id = uid returning plant_id)
  select coalesce(array_agg(plant_id order by plant_id), '{}') into gone from d;

  delete from public.email_queue e
   where e.user_id = uid
     and ((e.plant_id = any (gone) and e.kind not like 'sunsynk_%') or e.key like 'needs_relink:' || p_account || ':%');

  select refresh_secret_id into sid from private.sunsynk_accounts where id = p_account;
  if sid is not null then delete from vault.secrets where id = sid; end if;
  update private.inverters set account_id = null where account_id = p_account;
  delete from private.sunsynk_accounts where id = p_account;

  select coalesce(array_agg(g order by g), '{}') into orphans
    from unnest(gone) g
   where not exists (select 1 from public.plant_users o where o.plant_id = g and o.user_id <> uid);
  perform private.plants_tombstone(orphans);

  return jsonb_build_object(
    'plantsRemoved', coalesce(array_length(gone, 1), 0),
    'queued',        coalesce(array_length(orphans, 1), 0));
end $$;
