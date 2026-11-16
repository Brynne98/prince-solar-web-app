-- ============================================================================
-- 0208 — the account's week starts from the plants that still have a week (SOLAR-565).
--
-- Before (0203): the account's row took the earliest week among the plants that
-- run. A login with Plant A (week used by another account) and Plant B (new) wrote
-- A's old week, so the account's week was over at once: pay screen for both, and
-- B's week was started and lost.
--
-- Now: the account's row takes the latest week among those plants that is still
-- inside its 7 days. Each plant keeps its own lock, so A stays shut and B runs its
-- 7 days. A plant on day 5 of its week, alone, still gives 2 days. With no plant
-- whose week is open, the rule of 0203 stands: the earliest week, at least 15 days
-- back.
-- ============================================================================

create or replace function private.week_start(p_user uuid, p_plants bigint[])
returns void language plpgsql set search_path = public, private, pg_temp as $$
declare
  run bigint[] := array(select pu.plant_id from public.plant_users pu
                         where pu.user_id = p_user and pu.plant_id = any (p_plants) and not pu.paused);
begin
  if cardinality(run) = 0 then return; end if;
  if coalesce((select plan from private.billing where user_id = p_user), 'free') = 'free'
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
         coalesce(w.open,
                  case when w.s > now() - interval '7 days' then w.s
                       else least(w.s, now() - interval '15 days') end)
    from (select coalesce(min(started_at), now()) as s,
                 max(started_at) filter (where started_at > now() - interval '7 days') as open
            from private.plant_week where plant_id = any (run)) w
  on conflict (user_id) do nothing;
end $$;
revoke all on function private.week_start(uuid, bigint[]) from public, anon, authenticated;
