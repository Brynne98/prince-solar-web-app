CREATE OR REPLACE FUNCTION public.plant_bootstrap_kick(p_plant bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  fn_base text;
  auth jsonb;
  acc uuid;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net not enabled here - not kicking bootstrap for plant %', p_plant;
    return;
  end if;
  fn_base := private.functions_url();                                     -- 0280
  auth := jsonb_build_object(
    'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
    'Content-Type', 'application/json');
  -- the 60 days and the kWh totals are History's queue now (SOLAR-686 H1): taken within a minute
  select account_id into acc from plants.user_plants where plant_id = p_plant limit 1;
  if acc is not null then
    perform net.http_post(
      url := fn_base || '/poll',
      headers := auth,
      body := jsonb_build_object('account', acc),
      timeout_milliseconds := 55000);
  end if;
end $function$;
