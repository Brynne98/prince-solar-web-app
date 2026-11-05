-- ============================================================================
-- 0155 — Admin can delete a user's account (SOLAR-358).
--
-- A user can ask by email to be deleted. The admin page now has a Delete button
-- per user. It calls admin_account_delete(email), which runs the same checks and
-- deletes as the user's own Delete account, so neither path can drift:
--   * private.account_delete(uid) — 0132's api_account_delete body, unchanged,
--     with the user passed in.
--   * api_account_delete() — the user's own delete: auth.uid().
--   * admin_account_delete(email) — admins only; refuses an admin's account, so
--     the page cannot lock its own user out.
-- ============================================================================

create or replace function private.account_delete(uid uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, vault, pg_temp
as $$
declare
  b private.billing;
  acc record;
  p bigint;
  mine bigint[];
  orphans bigint[];
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  -- Charge rows before the user lock, as billing_charge_paid takes them.
  perform 1 from private.billing_charges where user_id = uid order by reference for update;
  perform private.billing_lock(uid);
  select * into b from private.billing where user_id = uid for update;
  if b.state = 'past_due' or exists (select 1 from private.billing_charges where user_id = uid and dispute_owed) then
    raise exception 'pay what is owed first' using errcode = '22023';
  end if;
  if exists (select 1 from private.billing_charges
              where user_id = uid and status = 'pending' and kind in ('start', 'upgrade', 'settle')
                and created_at > now() - interval '1 day') then
    raise exception 'a payment is open' using errcode = '22023';
  end if;
  -- Money still to go back: the charge row it needs goes with the account.
  if exists (select 1 from private.billing_charges
              where user_id = uid and status = 'paid' and (kind = 'card' or error like 'refund%')
                and coalesce(refund_status, 'failed') = 'failed' and not refund_alerted) then  -- alerted: hello@ refunds it
    raise exception 'a payment is open' using errcode = '22023';
  end if;
  if b.plan <> 'free' and not b.comped and b.next_plan is distinct from 'free' then
    raise exception 'cancel your plan first' using errcode = '22023';
  end if;

  for acc in select id from private.sunsynk_accounts where user_id = uid order by id loop
    perform pg_advisory_xact_lock(1, hashtext(acc.id::text));
  end loop;
  select coalesce(array_agg(plant_id order by plant_id), '{}') into mine
    from public.plant_users where user_id = uid;
  foreach p in array mine loop perform pg_advisory_xact_lock(p); end loop;
  select coalesce(array_agg(g order by g), '{}') into orphans
    from unnest(mine) g
   where not exists (select 1 from public.plant_users o where o.plant_id = g and o.user_id <> uid);

  for acc in select id, refresh_secret_id from private.sunsynk_accounts where user_id = uid loop
    if acc.refresh_secret_id is not null then delete from vault.secrets where id = acc.refresh_secret_id; end if;
    update private.inverters set account_id = null where account_id = acc.id;
  end loop;
  delete from private.sunsynk_accounts where user_id = uid;

  delete from public.plant_users where user_id = uid;
  perform private.plants_tombstone(orphans);

  insert into public.email_queue (to_email, kind, key, priority)
  select email, 'account_deleted', 'account_deleted:' || uid, 1 from auth.users where id = uid and email is not null
  on conflict do nothing;

  delete from public.profiles where user_id = uid;
  delete from auth.users where id = uid;
  return jsonb_build_object('deleted', true, 'plantsRemoved', coalesce(array_length(orphans, 1), 0));
end $$;
revoke all on function private.account_delete(uuid) from public, anon, authenticated;

create or replace function public.api_account_delete()
returns jsonb
language sql
security definer
set search_path = public, private, pg_temp
as $$ select private.account_delete(auth.uid()) $$;
revoke all on function public.api_account_delete() from public, anon;
grant execute on function public.api_account_delete() to authenticated, service_role;

create or replace function public.admin_account_delete(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare uid uuid;
begin
  perform private.require_admin();
  select id into uid from auth.users where lower(email) = lower(btrim(p_email));
  if uid is null then raise exception 'no such user' using errcode = '22023'; end if;
  if exists (select 1 from private.admins a where a.user_id = uid) then
    raise exception 'an admin account is deleted from its own Settings' using errcode = '22023';
  end if;
  return private.account_delete(uid);
end $$;
revoke all on function public.admin_account_delete(text) from public, anon;
grant execute on function public.admin_account_delete(text) to authenticated;
