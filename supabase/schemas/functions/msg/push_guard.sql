CREATE OR REPLACE FUNCTION msg.push_guard(p_o msg.outbox)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case
           when p_o.expires_at <= now() then 'too old'
           when q.id is null then 'event gone'
           when q.plant_id is not null
                and not exists (select 1 from plants.user_plants pu where pu.user_id = q.user_id and pu.plant_id = q.plant_id)
             then 'plant removed'
           when q.plant_id is not null and not exists (
                  select 1 from billing.seats se join billing.accounts ba on ba.id = se.account
                   where ba.user_id = q.user_id and se.plant = q.plant_id and se.closed_at is null)
             then 'plant not chosen'
           -- needs_relink is queued just before the login is marked broken (trigger order on
           -- sunsynk_accounts), so its plant is never read at send time: no live test for the login kinds
           when q.plant_id is not null and q.kind not in ('needs_relink', 'relinked')
                and not private.plant_live(q.user_id, q.plant_id) then 'plant not live'
           when not private.push_wanted(q.user_id, private.email_switch(q.kind)) then 'switched off'
           when q.pair_key is not null then
             case msg.push_down_state(q.user_id, q.pair_key)
               when 'wait' then 'wait' when 'dropped' then 'down had no pop-up' end
         end
    from (select 1) one
    left join public.email_queue q on q.id = p_o.event_id
$function$;
