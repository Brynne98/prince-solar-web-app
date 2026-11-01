-- ============================================================================
-- 0134 — undoing a booked change is emailed (SOLAR-271, Brynne 2026-11-01).
--
-- Booking a cancel, downgrade or period switch sends bill_change (0116). Keep undid it
-- and sent nothing, so the inbox still said the plan ends. An undo of a booked change
-- now sends bill_kept: the plan, and the next payment. An undo with nothing booked
-- sends nothing, as before.
-- ============================================================================

create or replace function public.api_billing_change(p_plan text, p_period text default null)
returns jsonb language plpgsql security definer set search_path = public, private, pg_temp as $$
declare b private.billing; was_booked boolean;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  -- for update: a double tap undoes once and emails once
  select next_plan is not null or next_period is not null into was_booked from private.billing where user_id = auth.uid() for update;
  perform public.billing_book_change(auth.uid(), p_plan, p_period);
  select * into b from private.billing where user_id = auth.uid();
  if b.next_plan is not null or b.next_period is not null then
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (auth.uid(), 'bill_change', 'bill_change:' || gen_random_uuid(),
            jsonb_build_object('from', b.plan, 'to', coalesce(b.next_plan, b.plan),
              'fromPeriod', b.period, 'toPeriod', coalesce(b.next_period, b.period), 'on', b.next_billing_date,
              'nextAmount', case when coalesce(b.next_plan, b.plan) <> 'free' then public.billing_amount_due(auth.uid()) end,
              'removePlants', coalesce((select jsonb_agg(pu.plant_name order by pu.linked_at) from public.plant_users pu
                                         where pu.user_id = auth.uid() and pu.plant_id = any (b.plants_to_remove)), '[]'::jsonb)),
            1);
  elsif was_booked then
    insert into public.email_queue (user_id, kind, key, data, priority)
    values (auth.uid(), 'bill_kept', 'bill_kept:' || gen_random_uuid(),
            jsonb_build_object('plan', b.plan, 'period', b.period, 'on', b.next_billing_date,
              'nextAmount', public.billing_amount_due(auth.uid())),
            1);
  end if;
  return public.api_billing_status();
end $$;
