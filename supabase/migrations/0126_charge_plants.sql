-- ============================================================================
-- 0126 — a charge names the plants it pays for (SOLAR-263).
--
-- Family plants past the 3rd now link stopped and start once their R49 an inverter
-- is paid (link-sunsynk). billing_resume started the oldest stopped plants that fit
-- the paid inverters, so a plant the user had stopped could start in place of the
-- one just paid for. The charge now keeps the plant ids (billing_charges.plants) and
-- billing_resume starts only those. No ids (upgrade, "Start stopped plants"): as before.
-- ============================================================================

alter table private.billing_charges add column if not exists plants bigint[];

drop function if exists public.billing_charge_open(uuid, text, text, int);
-- The 4th argument was renamed p_extra -> p_added after this ran in production, and a
-- rename needs a drop: without it a fresh setup stops here (SOLAR-301).
drop function if exists public.billing_charge_open(uuid, text, text, int, bigint[]);
create or replace function public.billing_charge_open(
  p_user uuid, p_plan text, p_period text default null, p_added int default 0, p_plants bigint[] default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  q jsonb;
  ref text := 'psh_' || replace(gen_random_uuid()::text, '-', '');
  v_kind text;
  v_period text;
  today date := private.billing_today();
begin
  select * into b from private.billing where user_id = p_user for update;
  if b.comped then raise exception 'this plan is free of charge' using errcode = '22023'; end if;
  if b.state = 'past_due' then raise exception 'settle the failed payment first' using errcode = '22023'; end if;
  v_kind := case when coalesce(b.plan, 'free') = 'free' then 'start' else 'upgrade' end;
  v_period := case when v_kind = 'start' then coalesce(p_period, 'monthly') else b.period end;
  if v_period not in ('monthly', 'yearly') or p_plan not in ('home', 'family') then
    raise exception 'unknown plan or period' using errcode = '22023';
  end if;
  q := public.billing_upgrade_quote(p_user, p_plan, greatest(p_added, 0),
         case when v_kind = 'start' then v_period end, today);
  if (q->>'dueNow')::int <= 0 then
    insert into private.billing_charges (reference, user_id, kind, plan, period, added, plants, amount, due_on, created_on)
    values (ref, p_user, v_kind, p_plan, v_period, greatest(p_added, 0), p_plants, 0, today, today);
    perform public.billing_charge_paid(ref, null, true);
    return jsonb_build_object('amount', 0, 'reference', ref);
  end if;
  insert into private.billing_charges (reference, user_id, kind, plan, period, added, plants, amount, due_on, created_on)
  values (ref, p_user, v_kind, p_plan, v_period, greatest(p_added, 0), p_plants, (q->>'dueNow')::int, today, today);
  return jsonb_build_object('reference', ref, 'amount', (q->>'dueNow')::int,
    'email', (select email from auth.users where id = p_user),
    'card', b.card->>'authorization_code');
end $$;

drop function if exists private.billing_resume(uuid, text, int);
create or replace function private.billing_resume(p_user uuid, p_plan text, p_added int, p_plants bigint[] default null)
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  active int := (select count(*) from public.plant_users where user_id = p_user and not paused);
  room int := p_added;
  resumed bigint[] := '{}';
  r record;
  others boolean;
begin
  for r in select pu.plant_id, (select count(*) from private.inverters i where i.plant_id = pu.plant_id)::int as inv
             from public.plant_users pu
            where pu.user_id = p_user and pu.paused and (p_plants is null or pu.plant_id = any (p_plants))
            order by pu.linked_at, pu.plant_id loop
    if active < coalesce(public.billing_plant_limit(p_plan), 3) then
      null;
    elsif p_plan = 'family' and r.inv <= room then
      room := room - r.inv;
    else
      exit;
    end if;
    others := exists (select 1 from public.plant_users where plant_id = r.plant_id and not paused);
    update public.plant_users set paused = false where user_id = p_user and plant_id = r.plant_id;
    if not others then perform private.plant_start_fill(r.plant_id); end if;
    active := active + 1;
    resumed := resumed || r.plant_id;
  end loop;
  -- A plant stopped by a move to Free and now resumed is no longer up for deletion;
  -- the ones still paused stay booked.
  update private.billing
     set plants_to_remove = array(select x from unnest(plants_to_remove) x where x <> all (resumed)),
         remove_on = case when plants_to_remove <@ resumed then null else remove_on end
   where user_id = p_user and plants_to_remove && resumed;
end $$;

create or replace function public.billing_charge_paid(p_reference text, p_card jsonb default null,
  p_quiet boolean default false, p_cents bigint default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  c private.billing_charges;
  b private.billing;
  today date := private.billing_today();
  v_from text;
begin
  select * into c from private.billing_charges where reference = p_reference for update;
  if not found then raise exception 'unknown reference' using errcode = 'P0002'; end if;
  if c.kind = 'card' then
    if c.status <> 'paid' then
      if p_cents is not null and p_cents <> c.amount * 100 then
        raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
      end if;
      update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;
      if p_card is not null and coalesce((p_card->>'reusable')::boolean, false) then
        update private.billing set card = p_card, card_email = (select email from auth.users where id = c.user_id),
               updated_at = now()
         where user_id = c.user_id;
      else
        update private.billing_charges set error = 'card not reusable: not saved' where reference = p_reference;
      end if;
    end if;
    return jsonb_build_object('status', 'paid', 'kind', 'card', 'refund', c.refunded_at is null,
      'saved', p_card is not null and coalesce((p_card->>'reusable')::boolean, false));
  end if;
  if c.status = 'paid' then return jsonb_build_object('status', 'paid', 'again', true, 'kind', c.kind); end if;
  if p_cents is not null and p_cents <> c.amount * 100 then
    raise exception 'paid % cents, charge is R%', p_cents, c.amount using errcode = '22023';
  end if;
  select * into b from private.billing where user_id = c.user_id for update;
  v_from := coalesce(b.plan, 'free');
  -- Paid on a card page opened earlier, but the account has moved on since: a second
  -- start, an upgrade after a move to Free or a failed renewal, a second settle. Paystack has the
  -- money; nothing is applied. The error marks it for a refund from Paystack's dashboard.
  if (c.kind = 'start' and v_from <> 'free')
     or (c.kind = 'upgrade' and (v_from = 'free' or b.state = 'past_due' or b.period is distinct from c.period))
     or (c.kind = 'settle' and b.state is distinct from 'past_due') then
    update private.billing_charges set status = 'paid', settled_at = now(),
           error = 'refund: paid after the account changed (' || v_from || ', ' || coalesce(b.state, 'active') || ')'
     where reference = p_reference;
    raise warning 'billing charge % paid but not applied: refund it', p_reference;
    return jsonb_build_object('status', 'paid', 'applied', false, 'kind', c.kind);
  end if;
  update private.billing_charges set status = 'paid', error = null, settled_at = now() where reference = p_reference;

  if c.kind = 'start' then
    insert into private.billing (user_id, plan, period, billing_day, next_billing_date)
    values (c.user_id, c.plan, c.period, extract(day from today)::int,
            public.billing_step(today, c.period, extract(day from today)::int, 1))
    on conflict (user_id) do update
      set plan = excluded.plan, period = excluded.period, billing_day = excluded.billing_day,
          next_billing_date = excluded.next_billing_date, next_plan = null, next_period = null,
          state = 'active', past_due_since = null, updated_at = now();
  elsif c.kind = 'upgrade' then
    update private.billing set plan = c.plan, next_plan = null, updated_at = now()
     where user_id = c.user_id;
  else  -- renewal, settle
    update private.billing set state = 'active', past_due_since = null, updated_at = now() where user_id = c.user_id;
  end if;
  if c.kind in ('start', 'upgrade') then
    perform private.billing_resume(c.user_id, c.plan, c.added, c.plants);
  end if;
  if p_card is not null and coalesce((p_card->>'reusable')::boolean, false) then
    update private.billing set card = p_card, card_email = (select email from auth.users where id = c.user_id)
     where user_id = c.user_id;
  end if;

  if not p_quiet then
    select * into b from private.billing where user_id = c.user_id;
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (c.user_id,
            case when c.kind in ('start', 'upgrade') then 'bill_upgraded' else 'bill_paid' end,
            'bill:' || p_reference,
            jsonb_build_object('from', v_from, 'to', b.plan, 'plan', b.plan, 'period', b.period,
              'amount', c.amount, 'date', today, 'reference', p_reference,
              'card', private.billing_card_label(coalesce(p_card, b.card)),
              'added', c.added, 'daysLeft', b.next_billing_date - today,
              'extra', public.billing_extra_inverters(c.user_id),
              'extraEach', public.billing_amount('family', b.period, 1) - public.billing_amount('family', b.period, 0),
              'nextAmount', public.billing_amount_due(c.user_id), 'nextDate', b.next_billing_date),
            1)
    on conflict do nothing;
  end if;
  return jsonb_build_object('status', 'paid', 'plan', b.plan, 'kind', c.kind);
end $$;

revoke all on function public.billing_charge_open(uuid, text, text, int, bigint[]) from public, anon, authenticated;
grant execute on function public.billing_charge_open(uuid, text, text, int, bigint[]) to service_role;
revoke all on function private.billing_resume(uuid, text, int, bigint[]) from public, anon, authenticated;
