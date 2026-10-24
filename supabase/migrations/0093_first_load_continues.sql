-- SOLAR-167: a newly added plant's first 60 days load in one go.
--
-- plant_bootstrap_kick (0044) runs recover once when a plant is linked. A run stops
-- on its time budget, and until now the next one came with the 6-hourly
-- sunsynk-recover schedule, so "Fetching history" sat at the same percentage for
-- hours. This job runs recover for each plant whose first load is still pending
-- (backfill_next set, or temperatures more than a day behind) every 2 minutes until
-- it is done. "More than a day": every plant's temp_next falls one day behind at
-- midnight, and a day that keeps failing (the parents' sticky 504) must not turn
-- into a run every 2 minutes; the 6-hourly schedule covers those. Overlapping runs are safe: each day is claimed
-- with a compare-and-set on the bookmark (recover backfillPlant, 0044).
-- Production only, as 0030.

create or replace function private.first_load_continue()
returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  p bigint;
begin
  for p in
    select pc.plant_id from public.plant_config pc
     where pc.backfill_next is not null
        or (pc.temp_next is not null and pc.temp_next < public.today_tz(coalesce(pc.timezone, 'Africa/Johannesburg')) - 1)
  loop
    perform net.http_post(
      url := 'https://pmakzojwhouamawgszrc.functions.supabase.co/recover?plant=' || p,
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
        'Content-Type', 'application/json'),
      body := '{}'::jsonb,
      timeout_milliseconds := 150000);
  end loop;
end $$;
revoke all on function private.first_load_continue() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     or not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_cron/pg_net not enabled here - skipping first-load-continue schedule (expected on the local stack)';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'first-load-continue') then
    perform cron.unschedule('first-load-continue');
  end if;
  perform cron.schedule('first-load-continue', '*/2 * * * *', 'select private.first_load_continue()');
end $$;
