-- ============================================================================
-- 0121 — the free week is per account, not per SunSynk login (SOLAR-241).
--
-- Decided 2026-10-29, replacing 0110's guard b ("one free week per SunSynk login"):
--   - Every account gets one free week, on any plant, even one another account has.
--   - It starts when the account links its first plant. Swapping plants never
--     restarts it: the account keeps its one row here.
--   - After the week Free still covers one plant with the last 24 h (0111). A plant
--     linked then gets no 60-day pull: recover skips plants in free_trimmed_plants.
--
-- private.free_week_logins keeps its name (0111 and 0114 read it by user_id, and
-- already take the account's earliest row). sunsynk_username stays as the login that
-- started the week.
-- ============================================================================

-- One row per account: the earliest one wins.
delete from private.free_week_logins f
 using private.free_week_logins g
 where g.user_id = f.user_id
   and (g.started_at, g.sunsynk_username) < (f.started_at, f.sunsynk_username);
alter table private.free_week_logins drop constraint if exists free_week_logins_pkey;
alter table private.free_week_logins add primary key (user_id);

-- 0110's body without guard b. p_sunsynk_username is unused now; the signature
-- stays so the callers and grants don't change.
create or replace function public.billing_may_link(p_user uuid, p_sunsynk_username text, p_plant_inverters int[])
returns jsonb language plpgsql stable security definer set search_path = public, private, pg_temp as $$
declare
  v_plan text := coalesce((select b.plan from private.billing b where b.user_id = p_user), 'free');
  have int := (select count(*) from public.plant_users
                where user_id = p_user and not paused
                  and plant_id <> all (coalesce((select b.plants_to_remove from private.billing b
                                                  where b.user_id = p_user), '{}')));
  extra int;
begin
  select coalesce(sum(n), 0) into extra
    from unnest(p_plant_inverters) with ordinality as t(n, i) where have + i > 3;
  if have + coalesce(cardinality(p_plant_inverters), 0) > coalesce(public.billing_plant_limit(v_plan), 2147483647) then
    return jsonb_build_object('ok', false, 'reason', 'upgrade_needed', 'extraInverters', extra);
  end if;
  -- Never billed: extra inverters cost nothing, so nothing to confirm.
  if exists (select 1 from private.billing b where b.user_id = p_user and b.comped) then
    return jsonb_build_object('ok', true, 'extraInverters', 0, 'dueNow', 0);
  end if;
  return jsonb_build_object('ok', true, 'extraInverters', extra,
    'dueNow', case when v_plan = 'family' and extra > 0
                   then (public.billing_upgrade_quote(p_user, 'family', extra))->'dueNow' else '0' end);
end $$;

-- A Free link starts the account's free week, once. A paid link records nothing.
create or replace function public.billing_free_week_start(p_user uuid, p_sunsynk_username text)
returns void language sql security definer set search_path = public, private, pg_temp as $$
  insert into private.free_week_logins (sunsynk_username, user_id)
  select lower(p_sunsynk_username), p_user
   where coalesce((select plan from private.billing where user_id = p_user), 'free') = 'free'
  on conflict (user_id) do nothing
$$;
