CREATE OR REPLACE FUNCTION plants.unclaim(p_account uuid, p_plants bigint[], p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare closed bigint[];
begin
  perform billing.lock_account(p_account);
  perform billing.lock_plants(p_plants);
  delete from plants.claims where account = p_account and plant = any (p_plants);
  with c as (
    update billing.seats set closed_at = p_at, close_reason = 'login_removed'
     where account = p_account and closed_at is null and plant = any (p_plants)
       and not billing.has_route(p_account, plant, false)
    returning plant)
  select coalesce(array_agg(plant order by plant), '{}') into closed from c;
  perform plants.bump(p_plants);
  perform billing.purge_now(x, p_at) from unnest(closed) x;
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'unclaim', null,
                            jsonb_build_object('plants', to_jsonb(p_plants), 'closed', to_jsonb(closed)));
  return billing.account_state(p_account, p_at);
end $function$;
