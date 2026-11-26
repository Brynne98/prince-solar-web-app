CREATE OR REPLACE FUNCTION billing.claim_plant(p_account uuid, p_plant bigint, p_name text, p_brand text DEFAULT 'sunsynk'::text, p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare st billing.status; holder uuid;
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  insert into billing.plants (id, brand, external_id) values (p_plant, p_brand, p_plant::text) on conflict (id) do nothing;
  perform billing.lock_plants(array[p_plant]);
  select account into holder from billing.plant_claims where plant = p_plant;
  if holder is not null and holder <> p_account then raise exception 'taken' using errcode = '22023'; end if;
  if holder is not null then
    update billing.plant_claims set plant_name = coalesce(p_name, plant_name) where plant = p_plant;
  else
    if st.state = 'ended' and not billing.has_route(p_account, p_plant, false) then
      raise exception 'no plant can be added without a plan' using errcode = '22023';
    end if;
    insert into billing.plant_claims (plant, account, claimed_at, plant_name) values (p_plant, p_account, p_at, p_name);
    update billing.plants set version = version + 1 where id = p_plant;
    update billing.accounts set version = version + 1 where id = p_account;
    perform billing.log_event(p_account, p_at, p_actor, 'claim_plant', jsonb_build_object('state', st.state),
                              jsonb_build_object('plant', p_plant, 'name', p_name));
  end if;
  return billing.account_state(p_account, p_at);
end $function$;
