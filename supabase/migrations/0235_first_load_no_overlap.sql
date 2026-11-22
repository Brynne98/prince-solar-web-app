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

-- The link's own kick starts the first recover run, so it records its request too;
-- otherwise first_load_continue starts a second run 2 minutes later (code review).
-- plant_bootstrap_kick is the 0094 body; only the lines marked 0235 are new.
create or replace function public.plant_bootstrap_kick(p_plant bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  fn_base text := 'https://pmakzojwhouamawgszrc.functions.supabase.co';
  fn text;
  auth jsonb;
  acc uuid;
  rid bigint;                                                             -- 0235
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net not enabled here - not kicking bootstrap for plant %', p_plant;
    return;
  end if;
  auth := jsonb_build_object(
    'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
    'Content-Type', 'application/json');
  foreach fn in array array['sync-plant-energy', 'recover'] loop
    rid := net.http_post(                                                 -- 0235: keep the id
      url := fn_base || '/' || fn || '?plant=' || p_plant,
      headers := auth,
      body := '{}'::jsonb,
      timeout_milliseconds := 150000);
    if fn = 'recover' then                                                -- 0235
      insert into private.recover_kicks (plant_id, request_id)
        select p_plant, rid where exists (select 1 from public.plant_config where plant_id = p_plant)
        on conflict (plant_id) do update set request_id = excluded.request_id, at = now();
    end if;
  end loop;
  select account_id into acc from public.plant_users where plant_id = p_plant limit 1;
  if acc is not null then
    perform net.http_post(
      url := fn_base || '/poll',
      headers := auth,
      body := jsonb_build_object('account', acc),
      timeout_milliseconds := 55000);
  end if;
end $$;
revoke all on function public.plant_bootstrap_kick(bigint) from public, anon, authenticated;
