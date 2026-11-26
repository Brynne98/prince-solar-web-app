CREATE OR REPLACE FUNCTION public.billing_jobs(p_cmd text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  return case p_cmd
    when 'history_take' then billing.history_take()
    when 'history_step' then billing.history_step((p_args->>'id')::bigint, (p_args->>'day')::date,
                               coalesce((p_args->>'failed')::boolean, false), coalesce((p_args->>'throttled')::boolean, false),
                               now(), (p_args->>'claim')::uuid)
    when 'history_renew' then to_jsonb(coalesce(billing.history_renew((p_args->>'id')::bigint, (p_args->>'claim')::uuid), false))
    when 'fetching'     then coalesce((select jsonb_agg(distinct plant) from billing.history_fetches
                                        where status in ('queued', 'running')), '[]'::jsonb)
    when 'login_seen'   then billing.login_seen((p_args->>'login')::uuid, p_args->'plants')
    when 'alerts'       then billing.alerts()
    when 'heartbeat'    then (select '{}'::jsonb from (select billing.heartbeat(p_args->>'job', now(), p_args->'result',
                               p_args->>'error')) x)
    when 'winback'      then billing.winback_return(p_args->>'reference')
    when 'outbox_sweep' then billing.outbox_sweep()
    when 'outbox_take'  then billing.outbox_take(coalesce((p_args->>'limit')::int, 50))
    when 'outbox_done'  then (select '{}'::jsonb from (select billing.outbox_done((p_args->>'id')::bigint,
                               (p_args->>'ok')::boolean, p_args->>'error', (p_args->>'retry_s')::int,
                               now(), coalesce((p_args->>'refund')::boolean, false))) x)
    else billing.unknown_command(p_cmd)
  end;
end $function$;
