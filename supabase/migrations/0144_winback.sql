-- ============================================================================
-- 0144 — "Sorry to see you go" when a cancelled plan ends (SOLAR-328).
--
-- One email each time a paid plan runs out on its date: billing_renew moves an
-- active, uncomped Home or Family account to Free because Free was booked. A failed
-- payment's move to Free (billing_to_free, state past_due) has its own email, and
-- the comped switch (comped true) sends nothing. unique (user_id, key) with the end
-- date in the key: a billing run that repeats queues nothing twice; a plan that
-- comes back and ends again sends again.
--
-- keepUntil is the end date + 30, the day stopped plants are deleted (billing_renew)
-- and the day readings stop being kept (SOLAR-329). No switch, like billing mail.
--
-- winback_return(reference) tells billing which "come back" email a first payment
-- from Free follows, for the winback_resubscribed_done event; `at` is when the charge
-- settled, so the webhook and /verify send the same event. Service role only.
-- ============================================================================

create or replace function private.billing_winback()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  insert into public.email_queue (user_id, kind, key, data, priority)
  values (new.user_id, 'winback', 'winback:' || old.next_billing_date,
          jsonb_build_object('from', old.plan, 'keepUntil', old.next_billing_date + 30), 1)
  on conflict do nothing;
  return null;
end $$;
revoke all on function private.billing_winback() from public, anon, authenticated;

drop trigger if exists billing_winback on private.billing;
create trigger billing_winback after update of plan on private.billing
  for each row
  when (old.plan in ('home', 'family') and new.plan = 'free' and old.state = 'active' and not old.comped
        and old.next_billing_date is not null)
  execute function private.billing_winback();

-- The latest "come back" email sent before this paid start charge, if any.
create or replace function public.winback_return(p_reference text)
returns table (user_id uuid, email_id bigint, days int, at timestamptz)
language sql stable security definer set search_path = public, private, pg_temp as $$
  select q.user_id, q.id, (c.settled_at::date - q.sent_at::date), c.settled_at
    from private.billing_charges c
    join lateral (select * from public.email_queue q
                   where q.user_id = c.user_id and q.kind = 'winback' and q.status = 'sent' and q.sent_at < c.created_at
                   order by q.sent_at desc limit 1) q on true
   where c.reference = p_reference and c.kind = 'start' and c.status = 'paid'
$$;
revoke all on function public.winback_return(text) from public, anon, authenticated;
grant execute on function public.winback_return(text) to service_role;

notify pgrst, 'reload schema';
