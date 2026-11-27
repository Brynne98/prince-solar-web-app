CREATE OR REPLACE FUNCTION public.history_jobs(p_cmd text, p_args jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return case p_cmd
    when 'take'      then history.take(coalesce((p_args->>'shard')::int, 0), coalesce((p_args->>'shards')::int, 1))
    when 'renew'     then to_jsonb(history.renew(p_args->>'step', (p_args->>'id')::bigint, (p_args->>'claim')::uuid))
    when 'done'      then history.step_done(p_args->>'step', (p_args->>'id')::bigint, (p_args->>'claim')::uuid,
                                            p_args->>'result', p_args->>'note')
    when 'missing'   then coalesce((select jsonb_agg(m.ts order by m.ts) from history.missing((p_args->>'id')::bigint) m), '[]')
    when 'minutes'   then to_jsonb(history.bank_minutes((p_args->>'id')::bigint, (p_args->>'claim')::uuid, p_args->'rows', p_args->>'source'))
    when 'extras'    then to_jsonb(history.bank_extras(p_args->>'step', (p_args->>'id')::bigint, (p_args->>'claim')::uuid,
                                                       p_args->>'sn', p_args->'rows'))
    when 'totals'    then to_jsonb(history.bank_totals((p_args->>'id')::bigint, (p_args->>'claim')::uuid, p_args->'rows'))
    when 'has_extras' then to_jsonb(history.has_extras((p_args->>'plant')::bigint, (p_args->>'day')::date))
    when 'check'     then history.check_queue()
    when 'totals_now' then to_jsonb(history.totals_now((p_args->>'plant')::bigint))
    when 'trim_plants' then coalesce((select jsonb_agg(p.id order by p.id) from plants.plant_info p), '[]')
    when 'stuck'     then history.stuck()
    when 'loading'   then to_jsonb(exists (select 1 from history.imports i where i.plant = (p_args->>'plant')::bigint and i.status = 'open'))
    else null
  end;
end $function$;
