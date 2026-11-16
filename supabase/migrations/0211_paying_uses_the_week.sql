-- ============================================================================
-- 0211 — paying uses up the free week; no login swap inside the free week
--        (SOLAR-568, decided by Brynne 2026-11-16).
--
-- Before:
--   (a) An account that paid before its first plant got its week row at the link,
--       dated that day. A plan that ended within 7 days of the link left the week
--       "running": no pay screen, every plant locked (no plant week was started on
--       a plan), and the day-5 "free week ends" email and bell notice.
--   (b) In its week, an account with no plan could remove its login and link
--       another. If that login's plants had all had their week, every plant locked
--       and no pay screen, because the account's own week still ran.
--
-- Now:
--   - An account that has a plan, or ever paid, has its week over: its row is dated
--     at least 15 days back (0200's and 0203's mark for a week that is over). At the
--     link (week_start), when a plan starts (billing_week_used), and once here for
--     rows already written. When the plan ends, unpaid_since is the plan's end: the
--     pay screen at once, the plan-ended emails, no free-week ones.
--   - link_login_allowed: in the week, with no plan, only the login the week started
--     on (the shared-plant login does not count). link.jsx's 'one login' text says
--     "Choose a plan to add another".
-- ============================================================================

-- 0208's week_start. Added: a plan, or a paid charge, dates the account's row as over.
create or replace function private.week_start(p_user uuid, p_plants bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  run bigint[] := array(select pu.plant_id from public.plant_users pu
                         where pu.user_id = p_user and pu.plant_id = any (p_plants) and not pu.paused);
  v_plan text := coalesce((select plan from private.billing where user_id = p_user), 'free');
begin
  if cardinality(run) = 0 then return; end if;
  if v_plan = 'free'
     and coalesce((select f.started_at > now() - interval '7 days'
                     from private.free_week_logins f where f.user_id = p_user), true) then
    insert into private.plant_week (plant_id) select x from unnest(run) x
    on conflict (plant_id) do nothing;
  end if;
  insert into private.free_week_logins (sunsynk_username, user_id, started_at)
  select lower(coalesce((select a.sunsynk_username from public.plant_users pu
                           join private.sunsynk_accounts a on a.id = pu.account_id
                          where pu.user_id = p_user and pu.plant_id = run[1]), '')),
         p_user,
         case when v_plan <> 'free' or private.had_plan(p_user)
              then least(w.at, now() - interval '15 days')
              else w.at end
    from (select coalesce(w.open,
                   case when w.s > now() - interval '7 days' then w.s
                        else least(w.s, now() - interval '15 days') end) as at
            from (select coalesce(min(started_at), now()) as s,
                         max(started_at) filter (where started_at > now() - interval '7 days') as open
                    from private.plant_week where plant_id = any (run)) w) w
  on conflict (user_id) do nothing;
end $$;
revoke all on function private.week_start(uuid, bigint[]) from public, anon, authenticated;

-- A plan starts: the account's week, running or not, is over.
create or replace function private.billing_week_used()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  update private.free_week_logins set started_at = now() - interval '15 days'
   where user_id = new.user_id and started_at > now() - interval '15 days';
  return null;
end $$;
revoke all on function private.billing_week_used() from public, anon, authenticated;

drop trigger if exists billing_week_used on private.billing;
create trigger billing_week_used after insert or update of plan on private.billing
  for each row when (new.plan <> 'free')
  execute function private.billing_week_used();

-- Rows already written for accounts that have a plan or paid.
update private.free_week_logins f set started_at = now() - interval '15 days'
 where f.started_at > now() - interval '15 days'
   and (coalesce((select b.plan from private.billing b where b.user_id = f.user_id), 'free') <> 'free'
        or private.had_plan(f.user_id));

-- 0203's link_login_allowed. Added: in the free week, only the week's own login.
create or replace function public.link_login_allowed(p_user uuid, p_username text)
returns boolean
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select coalesce((select b.plan from private.billing b where b.user_id = p_user), 'free') <> 'free'
      or (not exists (select 1 from private.sunsynk_accounts a
                       where a.user_id = p_user and a.kind = 'login' and lower(a.sunsynk_username) <> lower(p_username))
          and not exists (select 1 from private.free_week_logins f
                           where f.user_id = p_user and f.started_at > now() - interval '7 days'
                             and f.sunsynk_username not in ('', lower(p_username))
                             and f.sunsynk_username not in (select lower(s.sunsynk_username) from private.sunsynk_accounts s
                                                             where s.kind = 'share')))
$$;
revoke all on function public.link_login_allowed(uuid, text) from public, anon, authenticated;
grant execute on function public.link_login_allowed(uuid, text) to service_role;

notify pgrst, 'reload schema';
