CREATE OR REPLACE FUNCTION plants.claim(p_account uuid, p_brand text, p_vendor_id text, p_name text, p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  st billing.status;
  holder uuid;
  pid bigint;
  share uuid := (select s.id from plants.logins s where s.kind = 'share' and s.brand = p_brand);
begin
  if share is null then raise exception 'claim: no share login for %', p_brand; end if;
  perform pg_advisory_xact_lock(1, hashtext(share::text));
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  pid := plants.plant_for(p_brand, p_vendor_id);
  perform billing.lock_plants(array[pid]);
  select c.account into holder from plants.claims c where c.plant = pid;
  if holder is not null and holder <> p_account then raise exception 'taken' using errcode = '22023'; end if;
  insert into plants.login_plants as lp (login, plant, plant_name, last_seen_at, linked_at)
  values (share, pid, p_name, p_at, p_at)
  on conflict (login, plant) do update set gone_at = null, missing_since = null, last_seen_at = excluded.last_seen_at,
                                           plant_name = coalesce(excluded.plant_name, lp.plant_name);
  if holder is not null then
    update plants.claims set plant_name = coalesce(p_name, plant_name) where plant = pid;
    return pid;
  end if;
  if st.state = 'ended' and not billing.has_route(p_account, pid, false) then
    raise exception 'no plant can be added without a plan' using errcode = '22023';
  end if;
  insert into plants.claims (plant, account, claimed_at, plant_name) values (pid, p_account, p_at, p_name);
  perform plants.bump(array[pid]);
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'claim_plant', jsonb_build_object('state', st.state),
                            jsonb_build_object('plant', pid, 'name', p_name));
  return pid;
end $function$;
