CREATE OR REPLACE FUNCTION public.billing_links(p_cmd text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'private', 'pg_temp'
AS $function$
declare acc uuid;
begin
  -- waits for a billing run, before any other lock (SOLAR-438): the copy holds it exclusive,
  -- so no account, login or claim is written halfway across it (final re-score, Sol)
  perform pg_advisory_xact_lock_shared(3, 0);
  acc := billing.account_of((p_args->>'user')::uuid);
  return case p_cmd
    when 'state' then billing.account_state(acc) || jsonb_build_object('live', billing.is_live(),
                        'login_known', exists (select 1 from billing.logins l where l.account = acc
                                                  and lower(l.username) = lower(p_args->>'username')))
    -- the vault id is the stored login's own (private.sunsynk_accounts)
    when 'link_login' then billing.link_login(acc, coalesce(p_args->>'brand', 'sunsynk'), p_args->>'username',
                             (select sa.refresh_secret_id from private.sunsynk_accounts sa where sa.id = (p_args->>'login')::uuid),
                             p_args->'plants', now(), 'owner', (p_args->>'login')::uuid)
    when 'claim_plant' then billing.claim_plant(acc, (p_args->>'plant')::bigint, p_args->>'name')
    else billing.unknown_command(p_cmd)
  end;
end $function$;
