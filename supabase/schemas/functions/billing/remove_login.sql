CREATE OR REPLACE FUNCTION billing.remove_login(p_account uuid, p_login uuid, p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  st billing.status;
  reached bigint[];
  closed bigint[];
  unprotected bigint[];
begin
  perform billing.lock_account(p_account);
  if not exists (select 1 from billing.logins where id = p_login and account = p_account) then
    raise exception 'no such login on this account' using errcode = 'P0002';
  end if;
  st := billing.account_status(p_account, p_at);
  reached := array(select plant from billing.login_plants where login = p_login order by 1);
  perform billing.lock_plants(reached);

  delete from billing.logins where id = p_login;
  with c as (
    update billing.seats set closed_at = p_at, close_reason = 'login_removed'
     where account = p_account and closed_at is null and plant = any (reached)
       and not billing.has_route(p_account, plant, false)
    returning plant)
  select coalesce(array_agg(plant order by plant), '{}') into closed from c;
  update billing.plants set version = version + 1 where id = any (closed);

  unprotected := array(select x from unnest(closed) x
                        where not (billing.plant_state(x, p_at)->>'protected')::boolean);
  -- a closed plant nothing keeps is deleted now, under its lock (purge_now, 0246), so the
  -- pop-up's "history deleted now" is true
  perform billing.purge_now(x, p_at) from unnest(closed) x;
  update billing.accounts set version = version + 1 where id = p_account;
  perform billing.log_event(p_account, p_at, p_actor, 'remove_login',
                            jsonb_build_object('state', st.state, 'login', p_login, 'plants', to_jsonb(reached)),
                            jsonb_build_object('closed', to_jsonb(closed), 'unprotected', to_jsonb(unprotected)));
  return billing.account_state(p_account, p_at) || jsonb_build_object('unprotected', to_jsonb(unprotected));
end $function$;
