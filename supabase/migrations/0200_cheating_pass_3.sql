-- ============================================================================
-- 0200 — third cheating review, findings M1 and M2 (SOLAR-548).
--
-- M1. Before: an account whose payment has failed (state past_due) and that has a
-- place open could link a second SunSynk login with one plant, or claim a shared
-- plant. The plant got a tick, started, and got a 60-day fetch. 0198 refused the
-- owner's own tick and change in that state, and left these two paths.
-- Now: private.plant_pick_add gives no new tick in past_due, so the plant links
-- locked, as it does when no place is open. A plant that already has a tick is not
-- affected. Paying sets the state back to active, and the owner's tick, a link and
-- a claim work again. A payment that starts plants (billing_resume) runs after the
-- state is active.
--
-- M2. Before: 0199 wrote the account's free-week row for Free accounts only. A paid
-- account from before 0199 with no row kept its weekly, monthly and yearly reports
-- after a drop to Free (the hold-back in 0114 needs the row).
-- Now: every account that has a plant and no row gets one, dated 15 days back, the
-- date 0199 gives an account that joins after the week. That is past the week (7
-- days) and past the "ended" notice (day 7 to 14), and the emails go only on their
-- own day (2, 5, 7): no free week, no notice and no email.
-- ============================================================================

-- 0197's body with the state check.
create or replace function private.plant_pick_add(p_user uuid, p_plant bigint, p_name text)
returns boolean language plpgsql set search_path = public, private, pg_temp as $$
declare b private.billing;
begin
  if exists (select 1 from private.plant_picks where user_id = p_user and plant_id = p_plant) then return true; end if;
  select * into b from private.billing where user_id = p_user;
  if b.state = 'past_due' then return false; end if;  -- no new tick until the payment
  if not coalesce(b.comped, false)
     and (select count(*) from private.plant_picks where user_id = p_user) >= public.billing_room(b.plan, b.extra_plants) then
    return false;
  end if;
  insert into private.plant_picks (user_id, plant_id, plant_name) values (p_user, p_plant, p_name);
  return true;
end $$;
revoke all on function private.plant_pick_add(uuid, bigint, text) from public, anon, authenticated;

insert into private.free_week_logins (sunsynk_username, user_id, started_at)
select '', pu.user_id, now() - interval '15 days'
  from public.plant_users pu
 group by pu.user_id
on conflict (user_id) do nothing;
