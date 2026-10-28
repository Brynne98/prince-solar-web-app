-- ============================================================================
-- 0115 — accounts from before billing get Family, never billed (SOLAR-208,
-- decided 2026-10-28).
--
-- Every account that exists when this runs (on 2026-10-28 that is Brynne's and
-- her father's) gets Family with comped set: no charge, no billing date, no
-- extra-inverter cost, nothing paused, trimmed or held back. Accounts made later
-- start on Free. No names or emails here: the rule is "made before this ran".
-- ============================================================================

insert into private.billing (user_id, plan, comped)
select u.id, 'family', true from auth.users u
on conflict (user_id) do update
  set plan = 'family', comped = true, period = null, billing_day = null, next_billing_date = null,
      next_plan = null, next_period = null, updated_at = now();

-- Their plants were linked before plans existed: none is paused.
update public.plant_users pu set paused = false
  from private.billing b where b.user_id = pu.user_id and b.comped and pu.paused;
