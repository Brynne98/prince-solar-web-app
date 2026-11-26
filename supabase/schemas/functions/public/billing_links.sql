CREATE OR REPLACE FUNCTION public.billing_links(p_cmd text, p_args jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'private', 'pg_temp'
AS $function$
declare acc uuid;
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  acc := billing.account_of((p_args->>'user')::uuid);
  return case p_cmd
    when 'state' then billing.account_state(acc) || jsonb_build_object('live', true,
                        'login_known', exists (select 1 from plants.login_info l where l.account = acc
                                                  and lower(l.username) = lower(p_args->>'username')))
    when 'claim_plant' then (select billing.account_state(acc) from (select plants.claim(acc,
                               coalesce(p_args->>'brand', plants.default_brand()), p_args->>'plant', p_args->>'name')) x)
    else billing.unknown_command(p_cmd)
  end;
end
$function$;
