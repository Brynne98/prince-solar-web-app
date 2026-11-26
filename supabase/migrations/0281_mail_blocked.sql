-- SOLAR-679 F13: an address that bounced for good, marked our mail as spam, or that the mail
-- service already refuses (its own block list) gets no more mail from us. The mail service's
-- webhook (functions/resend-webhook) records it here through mail_block; every later email to
-- it is dropped at take time with drop_reason 'address blocked', a final state, never retried:
--   alert, report and other msg.outbox emails in msg.email_guard (msg_email_take);
--   billing outbox emails in billing.outbox_take.
-- Not covered on purpose: the admin error alarm (error-alert) and sign-in mail (Supabase Auth,
-- its own sender). Keyed on the address, lower case: a user who changes address gets mail again.
-- To let an address through again: delete its row.

create table private.mail_blocked (
  email    text primary key check (email = lower(btrim(email)) and email <> ''),
  reason   text not null check (reason in ('bounced', 'complained', 'suppressed')),
  detail   text,
  first_at timestamptz not null default now(),
  last_at  timestamptz not null default now(),
  events   integer not null default 1
);
alter table private.mail_blocked enable row level security;
revoke all on table private.mail_blocked from public, anon, authenticated;

CREATE OR REPLACE FUNCTION private.mail_blocked(p_email text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from private.mail_blocked b where b.email = lower(btrim(p_email)))
$function$;
revoke all on function private.mail_blocked(text) from public, anon, authenticated;

-- the webhook's write: one event's addresses; a repeat updates the row (Svix resends are safe)
CREATE OR REPLACE FUNCTION public.mail_block(p_emails text[], p_reason text, p_detail text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with r as (
    insert into private.mail_blocked as b (email, reason, detail)
    select distinct lower(btrim(e)), p_reason, left(p_detail, 500)
      from unnest(p_emails) e where nullif(btrim(e), '') is not null
    on conflict (email) do update
       set reason = excluded.reason, detail = excluded.detail, last_at = now(), events = b.events + 1
    returning 1)
  select count(*)::int from r
$function$;
revoke all on function public.mail_block(text[], text, text) from public, anon, authenticated;
grant execute on function public.mail_block(text[], text, text) to service_role;

CREATE OR REPLACE FUNCTION msg.email_guard(p_o msg.outbox)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
           when p_o.expires_at <= now() then 'too old'
           when q.id is null then 'event gone'
           -- kept in the app's bell, no email (notify build, SOLAR-415)
           when q.kind in ('batt_hot_back', 'bank_drift_back') then 'no email for this kind'
           when q.user_id is not null and private.email_switch_of(q.kind, q.data) is not null
                and not public.email_wanted(q.user_id, private.email_switch_of(q.kind, q.data)) then 'switched off'
           when q.plant_id is not null and q.user_id is not null and q.kind <> 'needs_relink'
                and not exists (select 1 from public.plant_users pu where pu.user_id = q.user_id and pu.plant_id = q.plant_id)
             then 'plant removed'
           -- plan, chosen plant, still reached: asked again when sent (email_claim 0247)
           when q.kind like 'report\_%' and q.user_id is not null
                and not billing.report_wanted((select ba.id from billing.accounts ba where ba.user_id = q.user_id), q.plant_id)
             then 'report not wanted'
           -- reconnect: the login may hold other chosen plants; email_claim never asked (review).
           -- share_removed / plant_off_login: the plant has just left the account.
           when q.plant_id is not null and q.user_id is not null and not msg.email_any_plant(q.kind) and not exists (
                  select 1 from billing.seats se join billing.accounts ba on ba.id = se.account
                   where ba.user_id = q.user_id and se.plant = q.plant_id and se.closed_at is null)
             then 'plant not chosen'
           -- needs_relink is queued just before the login is marked broken (0261)
           when q.plant_id is not null and q.user_id is not null and not msg.email_any_plant(q.kind)
                and not private.plant_live(q.user_id, q.plant_id) then 'plant not live'
           when q.kind = 'welcome' and exists (select 1 from public.plant_users pu where pu.user_id = q.user_id)
             then 'plant linked'
           when q.kind = 'need_a_hand' and exists (select 1 from private.sunsynk_accounts a where a.user_id = q.user_id)
                and not private.pick_waiting(q.user_id)
             then 'login added'
           when q.kind = 'add_plant_reminder'
                and (exists (select 1 from private.sunsynk_accounts a where a.user_id = q.user_id)
                     or exists (select 1 from public.plant_users pu where pu.user_id = q.user_id))
             then 'login or plant added'
           when coalesce(q.to_email, (select u.email::text from auth.users u where u.id = q.user_id), p_o.to_email) is null
             then 'no address'
           -- bounced for good, marked as spam or on the sender's block list (0281, SOLAR-679 F13)
           when private.mail_blocked(coalesce(q.to_email, (select u.email::text from auth.users u where u.id = q.user_id), p_o.to_email))
             then 'address blocked'
           when q.pair_key is not null then
             case msg.email_down_state(q.user_id, q.pair_key)
               when 'wait' then 'wait' when 'dropped' then 'down not sent' end
         end
    from (select 1) one
    left join public.email_queue q on q.id = p_o.event_id
$function$;

CREATE OR REPLACE FUNCTION billing.outbox_take(p_limit integer DEFAULT 50, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  o billing.outbox;
  why text;
  out jsonb := '[]';
  inv billing.invoices;
  att billing.payment_attempts;
  pm billing.payment_methods;
  u record;
begin
  -- before the switch the old emails still go; these wait and go once it is on
  if not billing.is_live() then return '[]'::jsonb; end if;
  for o in select * from billing.outbox
            where status = 'queued' and not_before <= p_at and (claimed_until is null or claimed_until <= p_at)
              -- held, not dropped: a renewal paid before the cutoff may still be answered (0248)
              and not case when key = 'plan_ended' then billing.plan_ended_held(account, ref, p_at)
                              when key = 'payment_reminder' then                                 -- 0276
                                (select c.stop is null and c.wait is not null
                                   from billing.payment_reminder_check(account, invoice, p_at) c)
                              else false end
            order by not_before, id limit p_limit for update skip locked loop
    why := billing.outbox_guard(o, p_at);
    if why is not null then
      update billing.outbox set status = 'dropped', drop_reason = why, claimed_until = null where id = o.id;
      continue;
    end if;
    select au.id, au.email, ep.unsub_token into u
      from billing.accounts a join auth.users au on au.id = a.user_id
      left join public.email_prefs ep on ep.user_id = au.id where a.id = o.account;
    if u.email is null then
      update billing.outbox set status = 'dropped', drop_reason = 'no email', claimed_until = null where id = o.id;
      continue;
    end if;
    -- 0281 (SOLAR-679 F13): bounced for good or marked as spam; never sent, so never tried again
    if private.mail_blocked(u.email) then
      update billing.outbox set status = 'dropped', drop_reason = 'address blocked', claimed_until = null where id = o.id;
      continue;
    end if;
    inv := null; att := null; pm := null;
    if o.invoice is not null then
      select * into inv from billing.invoices where id = o.invoice;
      select * into att from billing.payment_attempts where invoice = inv.id and status in ('success', 'failed')
       order by (status = 'success') desc, created_at desc limit 1;
      -- a failed or refused try's email names that try's card; card_update rows queued before
      -- 0248 have no ref: the latest refused saved-card try on the bill
      if o.key in ('payment_failed', 'card_update', 'payment_due') then
        select * into att from billing.payment_attempts where invoice = inv.id and id::text = o.ref;
        if att.id is null and o.key = 'card_update' then
          select * into att from billing.payment_attempts where invoice = inv.id and channel = 'saved_card' and hard_decline
           order by created_at desc limit 1;
        end if;
      end if;
      if att.payment_method is not null then select * into pm from billing.payment_methods where id = att.payment_method; end if;
    end if;
    update billing.outbox set claimed_until = p_at + interval '5 minutes', tries = tries + 1 where id = o.id;
    out := out || jsonb_build_array(jsonb_build_object(
      'id', o.id, 'key', o.key, 'user', u.id, 'email', u.email,
      -- a reminder always carries its unsubscribe link: the settings row is made if missing
      'unsub_token', case when (select reminder from billing.outbox_kinds where key = o.key)
                          then public.email_unsub_token(u.id) else u.unsub_token end,
      'reminder', (select reminder from billing.outbox_kinds where key = o.key),
      'state', billing.screen_state(o.account, p_at),
      -- the frozen bill a receipt reads
      'bill', case when inv.id is not null then jsonb_build_object(
                'kind', inv.kind, 'plan', inv.plan, 'plan_name', inv.plan_name,
                'interval', inv.interval, 'amount_minor', inv.amount_minor, 'currency', inv.currency,
                'next_amount_minor', case when inv.next_interval is not null
                  then (select np.amount_minor + inv.extra_places * np.extra_place_minor
                          from billing.price_keeping_offer(inv.plan, (select market from billing.accounts where id = inv.account),
                                                           inv.next_interval, inv.offer, inv.paid_at) np)
                  else inv.plan_amount_minor + inv.extra_places * inv.extra_place_minor end,
                'starts_now', inv.kind = 'upgrade' and inv.period_key like '%@%',
                'period_start', inv.period_start, 'period_end', inv.period_end, 'paid_at', inv.paid_at,
                'reference', att.reference, 'card_type', pm.card_type, 'last4', pm.last4) end,
      'refund', (select jsonb_build_object('amount_minor', coalesce(r.amount_minor, pa.amount_minor), 'currency',
                         coalesce(r.currency, pa.currency), 'reference', r.reference, 'reason', r.reason,
                         'paid_at', pa.settled_at, 'paid_minor', pa.amount_minor,
                         -- the card the refunded payment came from, not the one saved now
                         'card_type', rpm.card_type, 'last4', rpm.last4)
                   from billing.refunds r left join billing.payment_attempts pa on pa.id = r.attempt
                   left join billing.payment_methods rpm on rpm.id = pa.payment_method
                  where o.key = 'refund' and r.id = o.ref::uuid),
      -- a plan's end: its date, why, and whether a renewal payment was never answered
      'ended', case when o.key = 'plan_ended' then billing.plan_ended_facts(o) end,
      'event', (select jsonb_build_object('kind', e.kind, 'before', e.before, 'after', e.after)
                  from billing.account_events e where o.key in ('change_booked', 'change_undone') and e.id = o.ref::bigint),
      'plant', (select jsonb_build_object('id', p.id, 'name', coalesce((select lp.plant_name from billing.login_plants lp
                         join billing.logins l on l.id = lp.login where l.account = o.account and lp.plant = p.id limit 1),
                         (select pu.plant_name from public.plant_users pu where pu.plant_id = p.id and pu.user_id = u.id limit 1)))
                  from billing.plants p where o.key = 'history_deleted' and p.id = o.ref::bigint)));
  end loop;
  return out;
end $function$;
