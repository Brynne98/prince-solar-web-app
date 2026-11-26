CREATE OR REPLACE FUNCTION public.api_account_delete()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'vault', 'pg_temp'
AS $function$
declare
  uid uuid := auth.uid();
  acc record;
  gone jsonb;
  orphans bigint[];
begin
  -- 0247's lock order, kept: the billing-run lock, then the lock of each login its links hang on
  -- (its own and the share login), then the link rows, then the account (billing.delete_account).
  -- A reconnect, a claim of a lapsed share and the poller's share update take them in this order;
  -- the other way round deadlocks (scripts/billing-lock-test.mjs)
  perform pg_advisory_xact_lock_shared(3, 0);
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  for acc in select x.id from (select id from private.sunsynk_accounts where user_id = uid
                               union select account_id from public.plant_users where user_id = uid and account_id is not null) x
              order by x.id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
  end loop;
  perform 1 from public.plant_users where user_id = uid order by plant_id for update;
  gone := case when exists (select 1 from billing.accounts where user_id = uid)
               then billing.delete_account((select id from billing.accounts where user_id = uid))
               else jsonb_build_object('unprotected', '[]'::jsonb) end;
  orphans := array(select (x)::bigint from jsonb_array_elements_text(gone->'unprotected') x);
  for acc in select id, refresh_secret_id from private.sunsynk_accounts where user_id = uid order by id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
    if acc.refresh_secret_id is not null then delete from vault.secrets where id = acc.refresh_secret_id; end if;
    update private.inverters set account_id = null where account_id = acc.id;
  end loop;
  delete from private.sunsynk_accounts where user_id = uid;
  delete from public.plant_users where user_id = uid;
  insert into public.email_queue (to_email, kind, key, priority)
  select email, 'account_deleted', 'account_deleted:' || uid, 1 from auth.users where id = uid and email is not null
  on conflict do nothing;
  delete from public.profiles where user_id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(cardinality(orphans), 0));
end $function$;
