CREATE OR REPLACE FUNCTION billing.delete_account(p_account uuid, p_at timestamp with time zone DEFAULT now(), p_actor text DEFAULT 'owner'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  st billing.status;
  held bigint[];
  unprotected bigint[];
begin
  perform billing.lock_account(p_account);
  st := billing.account_status(p_account, p_at);
  if st.state not in ('none', 'trialing', 'ended') then
    raise exception 'a plan is running: cancel it and let it run out first' using errcode = '22023';
  end if;
  if exists (select 1 from billing.invoices where account = p_account and amount_owed_minor > 0) then
    raise exception 'money is owed' using errcode = '22023';
  end if;
  if exists (select 1 from billing.payment_attempts pa join billing.invoices i on i.id = pa.invoice
              where i.account = p_account and pa.dispute_open) then
    raise exception 'a dispute is open' using errcode = '22023';
  end if;
  held := array(select plant from billing.seats where account = p_account and closed_at is null order by plant);
  perform billing.lock_plants(held);
  update billing.invoices set status = 'void' where account = p_account and status = 'open';
  -- the bills' plan link first: in one delete, the account's set-null on a bill can fire after
  -- its plan row is gone and fail that bill's plan check (depends on the constraints' order)
  update billing.invoices set subscription = null where account = p_account and subscription is not null;
  delete from billing.accounts where id = p_account;
  perform plants.bump(held);
  unprotected := array(select x from unnest(held) x where not (billing.plant_state(x, p_at)->>'protected')::boolean);
  perform billing.log_event(p_account, p_at, p_actor, 'delete_account', jsonb_build_object('state', st.state),
                            jsonb_build_object('unprotected', to_jsonb(unprotected)));
  return jsonb_build_object('deleted', true, 'unprotected', to_jsonb(unprotected));
end $function$;
