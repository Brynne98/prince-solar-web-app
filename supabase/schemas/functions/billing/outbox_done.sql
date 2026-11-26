CREATE OR REPLACE FUNCTION billing.outbox_done(p_id bigint, p_ok boolean, p_error text DEFAULT NULL::text, p_retry_s integer DEFAULT NULL::integer, p_at timestamp with time zone DEFAULT now(), p_refund boolean DEFAULT false)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
  update billing.outbox
     set status = case when p_ok then 'sent' when p_retry_s is null or (tries >= 5 and not p_refund) then 'failed' else 'queued' end,
         sent_at = case when p_ok then p_at end,
         not_before = case when not p_ok and p_retry_s is not null then p_at + make_interval(secs => p_retry_s) else not_before end,
         tries = tries - case when p_refund and tries > 0 then 1 else 0 end,                -- 0257
         last_error = p_error, claimed_until = null
   where id = p_id
$function$;
