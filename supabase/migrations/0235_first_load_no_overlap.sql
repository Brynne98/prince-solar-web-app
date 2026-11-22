-- ============================================================================
-- 0235 — first_load_continue starts no second recover run on a plant whose last
-- one is still going (SOLAR-422, Review K item 3).
--
-- first_load_continue posts recover?plant=N every 2 minutes. A run's own budget
-- is 110 s, but a day already started is finished, and pg_net waits up to 150 s.
-- A slow run was still going when the next one started, and both fetched the same
-- days. private.recover_kicks keeps the last request per plant. A plant is skipped
-- while that request has no answer in net._http_response and is under 155 s old
-- (pg_net's 150 s cut plus a little). A fast run frees the plant at once, so a
-- first load keeps its 2-minute pace. A skipped refill goes back on the queue.
--
-- first_load_continue is the 0157 body; only the lines marked 0235 are new.
-- plpgsql, so net._http_response missing on the local stack is fine.
-- ============================================================================

create table if not exists private.recover_kicks (
  plant_id   bigint primary key references public.plant_config (plant_id) on delete cascade,
  request_id bigint not null,
  at         timestamptz not null default now()
);
revoke all on private.recover_kicks from public, anon, authenticated;

create or replace function private.first_load_continue()
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  p bigint;
  rid bigint;                                                             -- 0235
  has_net boolean := to_regclass('net._http_response') is not null;      -- 0235
begin
  for p in
    -- SOLAR-378: up to 50 plants waiting for a refill, oldest first.
    with taken as (
      delete from private.refill_queue q
       where q.plant_id in (select plant_id from private.refill_queue
                             order by queued_at limit 50 for update skip locked)
      returning q.plant_id
    )
    select plant_id from taken
    union
    select pc.plant_id from public.plant_config pc
     where pc.backfill_next is not null
        or (pc.temp_next is not null and pc.temp_next < public.today_tz(coalesce(pc.timezone, 'Africa/Johannesburg')) - 1)
  loop
    -- 0235: the last run on this plant is still going.
    if has_net and exists (
         select 1 from private.recover_kicks k
          where k.plant_id = p and k.at > now() - interval '155 seconds'
            and not exists (select 1 from net._http_response r where r.id = k.request_id)) then
      -- A refill taken off the queue waits for the next turn, not the 6-hourly run.
      insert into private.refill_queue (plant_id) values (p) on conflict do nothing;
      continue;
    end if;
    rid := net.http_post(                                                 -- 0235: keep the id
      url := 'https://pmakzojwhouamawgszrc.functions.supabase.co/recover?plant=' || p,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        'Content-Type', 'application/json'),
      body := '{}'::jsonb,
      timeout_milliseconds := 150000);
    insert into private.recover_kicks (plant_id, request_id) values (p, rid)   -- 0235
      on conflict (plant_id) do update set request_id = excluded.request_id, at = now();
  end loop;
end $$;
revoke all on function private.first_load_continue() from public, anon, authenticated;
