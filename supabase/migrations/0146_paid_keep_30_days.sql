-- ============================================================================
-- 0146 — a paid plan's readings stay 30 days after it ends (SOLAR-329).
--
-- private.billing.keep_until: set when a Home or Family plan (not comped) moves to
-- Free. A cancelled plan that runs out (state active): its end date + 30, the day
-- billing_renew deletes stopped plants and the date the "come back" email names
-- (0144). A failed payment's move (state past_due): the day of the move + 30, the
-- day billing_to_free deletes stopped plants. A paid plan clears it.
--
-- free_trimmed_plants (0111) skips an account until keep_until has passed, so the
-- hourly trim starts on day 31. An account that never paid has no keep_until and
-- is trimmed as before, once its free week ends.
-- ============================================================================

alter table private.billing add column if not exists keep_until date;

create or replace function private.billing_keep_until()
returns trigger language plpgsql set search_path = public, private, pg_temp as $$
begin
  if new.plan <> 'free' then
    new.keep_until := null;
  elsif old.plan in ('home', 'family') and not old.comped then
    new.keep_until := case when old.state = 'active' and old.next_billing_date is not null
                           then old.next_billing_date else private.billing_today() end + 30;
  end if;
  return new;
end $$;
revoke all on function private.billing_keep_until() from public, anon, authenticated;

drop trigger if exists billing_keep_until on private.billing;
create trigger billing_keep_until before update of plan on private.billing
  for each row when (old.plan is distinct from new.plan)
  execute function private.billing_keep_until();

-- 0111's list, with the 30 days after a paid plan.
create or replace function public.free_trimmed_plants()
returns setof bigint
language sql stable security definer set search_path = public, private, pg_temp
as $$
  select pu.plant_id
    from public.plant_users pu
    left join private.billing b on b.user_id = pu.user_id
    left join lateral (select min(started_at) as started from private.free_week_logins f
                        where f.user_id = pu.user_id) fw on true
   group by pu.plant_id
  having bool_and(coalesce(b.plan, 'free') = 'free' and fw.started is not null
                  and fw.started < now() - interval '7 days'
                  and (b.keep_until is null or b.keep_until < private.billing_today()))
$$;
