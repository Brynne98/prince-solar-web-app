CREATE OR REPLACE FUNCTION private.first_load_continue()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
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
end $function$;
