-- ============================================================================
-- 0224 — two counts for PostHog, read by the functions (SOLAR-584). Read only; no
--        table changes. For the ways around final plant picks (SOLAR-583) that were
--        allowed on purpose: delete and rejoin, and let a plan end then pay again.
--
--   - plants_seen_before(user, plants): of the plants just linked, how many had their
--     free week before this account was made and are held by no other account now.
--     An account deleted and made again, coming back to its plant, counts here.
--     Called by link-sunsynk and claim-share after a good link.
--   - billing_start_facts(reference): for a first payment ('start') not yet applied,
--     how long the account's last plan has been over, and how many of its running
--     plants were ticked after that plan ended (picked again while unpaid). Called by
--     billing before billing_charge_paid, which clears ended_at.
-- No plant ids, names or logins leave the database: counts and days only.
-- ============================================================================

create or replace function public.plants_seen_before(p_user uuid, p_plants bigint[])
returns int language sql stable security definer set search_path = public, private, pg_temp as $$
  select count(*)::int
    from private.plant_week w
   where w.plant_id = any (coalesce(p_plants, '{}'))
     and w.started_at < (select u.created_at from auth.users u where u.id = p_user)
     and not exists (select 1 from public.plant_users o
                      where o.plant_id = w.plant_id and o.user_id <> p_user and o.share_gone_at is null)
$$;
revoke all on function public.plants_seen_before(uuid, bigint[]) from public, anon, authenticated;
grant execute on function public.plants_seen_before(uuid, bigint[]) to service_role;

create or replace function public.billing_start_facts(p_reference text)
returns table (user_id uuid, days_since_plan int, picked_since int)
language sql stable security definer set search_path = public, private, pg_temp as $$
  select c.user_id,
         (private.billing_today() - (b.ended_at at time zone 'Africa/Johannesburg')::date)::int,
         (select count(*)::int from private.plant_picks k
            join public.plant_users pu on pu.user_id = k.user_id and pu.plant_id = k.plant_id and not pu.paused
           where k.user_id = c.user_id and k.picked_at > b.ended_at)
    from private.billing_charges c
    left join private.billing b on b.user_id = c.user_id
   where c.reference = p_reference and c.kind = 'start'
$$;
revoke all on function public.billing_start_facts(text) from public, anon, authenticated;
grant execute on function public.billing_start_facts(text) to service_role;

notify pgrst, 'reload schema';
