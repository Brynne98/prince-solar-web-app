CREATE OR REPLACE FUNCTION billing.unclaim(p_account uuid, p_plants bigint[], p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare closed bigint[];
begin
  perform billing.lock_account(p_account);
  perform billing.lock_plants(p_plants);
  delete from billing.plant_claims where account = p_account and plant = any (p_plants);
  with c as (
    update billing.seats set closed_at = p_at, close_reason = 'login_removed'
     where account = p_account and closed_at is null and plant = any (p_plants)
       and not billing.has_route(p_account, plant, false)
    returning plant)
  select coalesce(array_agg(plant order by plant), '{}') into closed from c;
  update billing.plants set version = version + 1 where id = any (p_plants);
  -- a closed plant nothing keeps is deleted now, under its lock
  perform billing.purge_now(x, p_at) from unnest(closed) x;
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'unclaim', null,
                            jsonb_build_object('plants', to_jsonb(p_plants), 'closed', to_jsonb(closed)));
  return billing.account_state(p_account, p_at);
end $function$;
