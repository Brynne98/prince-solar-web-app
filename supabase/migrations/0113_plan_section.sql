-- ============================================================================
-- 0113 — the Plan section in Account, and Remove login on a paid plan (SOLAR-208).
--
-- The signed-in user's own calls over the 0110 rules:
--   api_billing_status      plan, period, next payment and amount, a change booked
--                           for the billing date, plants booked for deletion
--   api_billing_change      book a downgrade, cancel or monthly/yearly switch; the
--                           current plan and period undo a booked change
--   api_billing_keep        take a plant off the deletion list
--   api_link_remove         Remove login: on a paid plan its plants stay until the
--                           billing date, then go (decided 2026-10-27); on Free the
--                           login goes at once, as api_link_disconnect did
-- Each answers for auth.uid() only. Upgrades are not here: they charge at once
-- (Paystack part).
-- ============================================================================

create or replace function public.api_billing_status()
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid();
  return jsonb_build_object(
    'plan', coalesce(b.plan, 'free'), 'period', b.period, 'state', coalesce(b.state, 'active'),
    'nextDate', b.next_billing_date,
    'nextAmount', public.billing_amount_due(auth.uid()),
    'price', public.billing_amount(coalesce(b.plan, 'free'), b.period, public.billing_extra_inverters(auth.uid())),
    'nextPlan', b.next_plan, 'nextPeriod', b.next_period,
    'removeOn', b.remove_on,
    'removePlants', coalesce((select jsonb_agg(jsonb_build_object('id', pu.plant_id, 'name', pu.plant_name) order by pu.linked_at)
                                from public.plant_users pu
                               where pu.user_id = auth.uid() and pu.plant_id = any (coalesce(b.plants_to_remove, '{}'))), '[]'::jsonb));
end $$;

create or replace function public.api_billing_change(p_plan text, p_period text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform public.billing_book_change(auth.uid(), p_plan, p_period);
  return public.api_billing_status();
end $$;

-- A plant a booked downgrade depends on can't be kept: undo the downgrade first.
create or replace function public.api_billing_keep(p_plant bigint)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into b from private.billing where user_id = auth.uid() for update;
  if b.next_plan is not null
     and (select count(*) from public.plant_users
           where user_id = auth.uid() and not paused
             and (plant_id = p_plant or plant_id <> all (b.plants_to_remove)))
         > coalesce(public.billing_plant_limit(b.next_plan), 2147483647) then
    raise exception 'needed for your plan change' using errcode = '22023';
  end if;
  update private.billing
     set plants_to_remove = array_remove(plants_to_remove, p_plant),
         remove_on = case when array_remove(plants_to_remove, p_plant) = '{}' then null else remove_on end,
         updated_at = now()
   where user_id = auth.uid();
  return public.api_billing_status();
end $$;

-- 'booked' with the date, or 'removed'.
create or replace function public.api_link_remove(p_account uuid)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing; p bigint;
begin
  if not exists (select 1 from private.sunsynk_accounts where id = p_account and user_id = auth.uid()) then
    raise exception 'not your account' using errcode = '42501';
  end if;
  select * into b from private.billing where user_id = auth.uid();
  -- A login with no plant has nothing to keep until the date.
  if b.plan is null or b.plan = 'free'
     or not exists (select 1 from public.plant_users where account_id = p_account and user_id = auth.uid()) then
    perform public.api_link_disconnect(p_account);
    return jsonb_build_object('result', 'removed');
  end if;
  for p in select plant_id from public.plant_users where account_id = p_account and user_id = auth.uid() loop
    perform public.billing_book_removal(auth.uid(), p);
  end loop;
  return jsonb_build_object('result', 'booked', 'on', b.next_billing_date);
end $$;

do $$
declare f text;
begin
  foreach f in array array['api_billing_status()', 'api_billing_change(text, text)', 'api_billing_keep(bigint)', 'api_link_remove(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
