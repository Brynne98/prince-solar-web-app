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
  for acc in select x.id from (select id from plants.login_info where user_id = uid
                               union select account_id from plants.user_plants where user_id = uid and account_id is not null) x
              order by x.id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
  end loop;
  perform 1 from plants.list_info lp join plants.login_info l on l.id = lp.login
   where l.user_id = uid order by lp.login, lp.plant for update of lp;
  -- the logins' secrets first: billing.delete_account's cascade takes the login rows with it
  for acc in select id, refresh_secret_id from plants.login_info where user_id = uid order by id loop
    if acc.refresh_secret_id is not null
       and not exists (select 1 from plants.login_info o where o.refresh_secret_id = acc.refresh_secret_id and o.user_id <> uid) then
      delete from vault.secrets s where s.id = acc.refresh_secret_id;
    end if;
  end loop;
  gone := case when exists (select 1 from billing.accounts where user_id = uid)
               then billing.delete_account((select id from billing.accounts where user_id = uid))
               else jsonb_build_object('unprotected', '[]'::jsonb) end;
  orphans := array(select (x)::bigint from jsonb_array_elements_text(gone->'unprotected') x);
  perform plants.user_logins_delete(uid);   -- its lists and events go with it; claims went with the account
  insert into public.email_queue (to_email, kind, key, priority)
  select email, 'account_deleted', 'account_deleted:' || uid, 1 from auth.users where id = uid and email is not null
  on conflict do nothing;
  delete from public.profiles where user_id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(cardinality(orphans), 0));
end $function$;
