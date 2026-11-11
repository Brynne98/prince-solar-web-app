-- ============================================================================
-- 0189 — no cancel or smaller plan while a payment has failed (SOLAR-497).
--
-- A renewal that failed is tried again on day 1, 3 and 7, and the account moves to Free on
-- day 8. A cancel or downgrade tapped in those days was booked for the next billing date, a
-- month on: the pop-up said "nothing changes until then", the card was still tried the next
-- day, and unpaid the account went to Free on day 8 anyway.
--
-- Brynne 2026-11-11: the retries always run; the service was used, so the payment is owed.
-- So a cancel, a smaller plan or a switch to monthly is refused until the payment is paid
-- ('pay the failed payment first'). A change booked before the payment failed stays booked,
-- and its undo (Keep <plan>) still works. Unpaid, the move to Free on day 8 is as before
-- (billing_to_free: 30 days kept).
--
-- billing_book_change is 0176's and api_billing_extras (extra plants held from before 0156)
-- is 0136's, each with the one check added.
-- ============================================================================

create or replace function public.billing_book_change(p_user uuid, p_plan text, p_period text default null,
  p_keep bigint[] default null)
returns void language plpgsql security definer set search_path = public, private, pg_temp as $$
declare
  b private.billing;
  rank constant jsonb := '{"free": 0, "home": 1, "family": 2}';
begin
  perform private.billing_lock(p_user);
  select * into b from private.billing where user_id = p_user for update;
  if b.plan is null or b.plan = 'free' then
    raise exception 'nothing to change on Free' using errcode = '22023';
  end if;
  if b.comped then
    raise exception 'this plan is free of charge' using errcode = '22023';
  end if;
  -- a cancel already booked (a second tab): nothing changes
  if b.next_plan = 'free' and p_plan = 'free' then
    return;
  end if;
  -- a failed payment: no cancel, smaller plan or period switch until it is paid (SOLAR-497).
  -- Keep <plan>, the undo of a change booked before the payment failed, still works.
  if b.state = 'past_due' and not (p_plan = b.plan and coalesce(p_period, b.period) = b.period) then
    raise exception 'pay the failed payment first' using errcode = '22023';
  end if;
  if b.prepaid_on is not null then
    -- a paid year: a cancel, or its undo back to the paid switch (SOLAR-467)
    if p_plan = b.plan then
      update private.billing set next_plan = null, next_keep = '{}', updated_at = now()
       where user_id = p_user and next_plan = 'free';
      return;
    end if;
    if p_plan <> 'free' then
      raise exception 'your year is paid: the plan stays until it starts' using errcode = '22023';
    end if;
    update private.billing
       set next_plan = 'free', next_keep = private.billing_keep_list(p_user, p_keep), updated_at = now()
     where user_id = p_user;
    return;
  end if;
  -- a booked cancel: only its undo, the plan as it is (SOLAR-467)
  if b.next_plan = 'free' and not (p_plan = b.plan and coalesce(p_period, b.period) = b.period) then
    raise exception 'your plan is cancelled: keep it first' using errcode = '22023';
  end if;
  if (rank->>p_plan)::int > (rank->>b.plan)::int then
    raise exception 'an upgrade starts at once, not at the billing date' using errcode = '22023';
  end if;
  if p_plan = b.plan and b.period = 'monthly' and p_period = 'yearly' then
    raise exception 'a switch to yearly is paid now, not booked' using errcode = '22023';
  end if;
  update private.billing
     set next_plan   = case when p_plan = b.plan then null else p_plan end,
         next_period = case when p_plan = 'free' or coalesce(p_period, b.period) = b.period then null
                            else p_period end,
         -- a new plan: the pick given (none: the first linked); a period switch or undo: the pick held
         -- a plan change or an undo takes a booked extras drop with it: one change (SOLAR-364)
         next_extra_plants = case when p_plan <> b.plan or coalesce(p_period, b.period) = b.period then null
                                  else next_extra_plants end,
         next_keep   = case when p_plan = b.plan and p_keep is null
                              then case when coalesce(p_period, b.period) = b.period or b.next_extra_plants is null then '{}' else next_keep end
                            else private.billing_keep_list(p_user, p_keep) end,
         updated_at  = now()
   where user_id = p_user;
end $$;

create or replace function public.api_billing_extras(p_count int, p_keep bigint[] default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform private.billing_lock(auth.uid());
  select * into b from private.billing where user_id = auth.uid() for update;
  if b.plan is distinct from 'family' or b.comped then
    raise exception 'extra plants are on Family only' using errcode = '22023';
  end if;
  if p_count is null or p_count < 0 or p_count > b.extra_plants then
    raise exception 'pay to add extra plants' using errcode = '22023';
  end if;
  -- a failed payment: no drop of held extra plants until it is paid; its undo still works (SOLAR-497)
  if b.state = 'past_due' and p_count <> b.extra_plants then
    raise exception 'pay the failed payment first' using errcode = '22023';
  end if;
  if b.next_plan is not null and p_count <> b.extra_plants then
    raise exception 'plan change' using errcode = '22023';
  end if;
  update private.billing
     set next_extra_plants = case when p_count = extra_plants then null else p_count end,
         next_keep = case when p_count = extra_plants and next_plan is null then '{}'
                          when p_count = extra_plants then next_keep
                          else private.billing_keep_list(auth.uid(), p_keep) end,
         updated_at = now()
   where user_id = auth.uid();
  return public.api_billing_status();
end $$;
