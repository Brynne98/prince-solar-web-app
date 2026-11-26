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
