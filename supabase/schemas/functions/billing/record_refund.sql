CREATE OR REPLACE FUNCTION billing.record_refund(p_refund uuid, p_error text, p_provider_id text, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare r billing.refunds;
begin
  update billing.refunds
     set status = case when p_error is null or p_error ~* 'already' then 'pending' else 'failed' end,
         last_error = p_error, provider_refund_id = coalesce(p_provider_id, provider_refund_id),
         claimed_until = null,
         next_try_at = case when p_error is null or p_error ~* 'already' then null else p_at + interval '1 hour' end,
         updated_at = p_at
   where id = p_refund and status in ('due', 'sending', 'failed')
  returning * into r;
  return to_jsonb(r);
end $function$;
