-- SOLAR-169: a newly linked plant gets its first live reading at once.
--
-- plant_bootstrap_kick (0044) started sync-plant-energy and recover for a new plant,
-- but the first live reading waited for the next minute's sunsynk-poll. It now also
-- asks poll for that plant's account straight away; poll takes {"account": id} and
-- polls only that account. Body as 0044 otherwise.

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
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net not enabled here - not kicking bootstrap for plant %', p_plant;
    return;
  end if;
  auth := jsonb_build_object(
    'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
    'Content-Type', 'application/json');
  foreach fn in array array['sync-plant-energy', 'recover'] loop
    perform net.http_post(
      url := fn_base || '/' || fn || '?plant=' || p_plant,
      headers := auth,
      body := '{}'::jsonb,
      timeout_milliseconds := 150000);
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
grant execute on function public.plant_bootstrap_kick(bigint) to service_role;
