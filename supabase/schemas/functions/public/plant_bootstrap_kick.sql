CREATE OR REPLACE FUNCTION public.plant_bootstrap_kick(p_plant bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  fn_base text;
  fn text;
  auth jsonb;
  acc uuid;
  rid bigint;                                                             -- 0235
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net not enabled here - not kicking bootstrap for plant %', p_plant;
    return;
  end if;
  fn_base := private.functions_url();                                     -- 0280
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
  select account_id into acc from plants.user_plants where plant_id = p_plant limit 1;
  if acc is not null then
    perform net.http_post(
      url := fn_base || '/poll',
      headers := auth,
      body := jsonb_build_object('account', acc),
      timeout_milliseconds := 55000);
  end if;
end $function$;
