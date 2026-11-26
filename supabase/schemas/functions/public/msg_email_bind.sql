CREATE OR REPLACE FUNCTION public.msg_email_bind(p_claim uuid, p_key text, p_ids bigint[])
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_n int;
begin
  update msg.outbox o set batch_key = p_key, claimed_until = now() + interval '2 minutes'
   where o.id = any (p_ids) and o.claim = p_claim and o.status = 'queued' and o.batch_key is null
     and o.channel = 'email';
  get diagnostics v_n = row_count;
  if v_n <> cardinality(p_ids) then
    raise exception 'msg_email_bind: % of % rows', v_n, cardinality(p_ids);
  end if;
  return true;
end $function$;
