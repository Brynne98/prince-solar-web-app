-- ============================================================================
-- 0100 — each poll shard reads only its own accounts. (SOLAR-146)
--
-- poll used plantsToPoll(): every shard read every active account (tokens
-- included), all of plant_users and the whole plant_config, then dropped all but
-- its own accounts. poll_jobs does the same work in SQL and returns only the rows
-- for one shard, so a shard's result scales with its ~10 accounts, not the fleet.
--
-- Same rules as plantsToPoll():
--   * one row per plant, read through the EARLIEST-linked active account that has
--     it (ties broken by id so the pick is stable minute to minute);
--   * the plant goes to that account's shard: first 8 hex digits of the account
--     uuid as an unsigned 32-bit number, mod p_shards (was shardOf() in poll);
--   * p_account set (link kick, 0094): only plants whose chosen account is that
--     one, whatever the shard.
-- Dates come back as text (YYYY-MM-DD), as PostgREST sent them before.
-- ============================================================================

create or replace function public.poll_jobs(p_shard int, p_shards int, p_account uuid default null)
returns table (
  plant_id bigint, plant_name text, timezone text, batt_positive_means text,
  backfill_next text, backfill_until text, backfill_tries int,
  temp_next text, temp_tries int, has_grid boolean,
  account_id uuid, user_id uuid, sunsynk_username text, access_token text, access_expires_at bigint)
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  with acc as (
    select a.id, a.user_id, a.sunsynk_username, a.access_token, a.access_expires_at,
           row_number() over (order by a.linked_at, a.id) as rank,
           ('x' || lpad(substr(replace(a.id::text, '-', ''), 1, 8), 16, '0'))::bit(64)::bigint
             % greatest(1, p_shards) as shard
      from private.sunsynk_accounts a
     where a.status = 'active'
  ),
  pick as (
    select distinct on (pu.plant_id) pu.plant_id, pu.plant_name, acc.*
      from public.plant_users pu
      join acc on acc.id = pu.account_id
     order by pu.plant_id, acc.rank
  )
  select p.plant_id, p.plant_name,
         coalesce(c.timezone, 'Africa/Johannesburg'), c.batt_positive_means,
         c.backfill_next::text, c.backfill_until::text, coalesce(c.backfill_tries, 0),
         c.temp_next::text, coalesce(c.temp_tries, 0), c.has_grid,
         p.id, p.user_id, p.sunsynk_username, p.access_token, p.access_expires_at
    from pick p
    left join public.plant_config c on c.plant_id = p.plant_id
   where case when p_account is not null then p.id = p_account else p.shard = p_shard end
   order by p.plant_id
$$;

revoke all on function public.poll_jobs(int, int, uuid) from public, anon, authenticated;
grant execute on function public.poll_jobs(int, int, uuid) to service_role;
