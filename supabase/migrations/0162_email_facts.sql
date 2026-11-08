-- ============================================================================
-- 0162 — Facts the new emails show (SOLAR-415).
--
--   email_billing_facts(user)    the saved card ("Visa •••• 4081") and the plan, for the
--                                renewal notice (which card is charged) and "plants are
--                                deleted" (Free keeps one plant, Home two).
--   email_plant_inverters(plant) each inverter's serial and newest reading time, so the
--                                "No readings" email lists every inverter by serial, not
--                                by its SunSynk alias ("Slave").
--
-- Read by notify with the service role only, like the other email_* readers (0092).
-- ============================================================================

create or replace function public.email_billing_facts(p_user uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'card', case when b.card is not null then private.billing_card_label(b.card) end,
    'plan', b.plan)
    from private.billing b where b.user_id = p_user
$$;

create or replace function public.email_plant_inverters(p_plant bigint)
returns table (sn text, last_dev bigint) language sql stable security definer set search_path = '' as $$
  select i.sn, s.last_dev
    from private.inverters i
    left join private.inverter_alert_state s on s.plant_id = i.plant_id and s.sn = i.sn
   where i.plant_id = p_plant
   order by i.sn
$$;

revoke all on function public.email_billing_facts(uuid), public.email_plant_inverters(bigint) from public, anon, authenticated;
grant execute on function public.email_billing_facts(uuid), public.email_plant_inverters(bigint) to service_role;
