CREATE OR REPLACE FUNCTION billing.run(p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  r record;
  one jsonb;
  charges jsonb := '[]';
  steps jsonb := '{}';
  verify jsonb;
  refunds jsonb;
begin
  if not pg_try_advisory_xact_lock(hashtext('billing.run')) then return jsonb_build_object('busy', true); end if;
  -- the way back from the switch is under way (billing.pause_payments): nothing is charged
  lock table billing.payments_pause in share mode;
  if exists (select 1 from billing.payments_pause) then return jsonb_build_object('busy', true); end if;
  -- Nothing is failed here without asking Paystack: a try with no answer is verified (below) and
  -- apply_payment fails it only when Paystack still says pending after 24 hours. Every change to
  -- a try goes through apply_payment under its account lock (account, then try).
  -- tries whose lease ran out: Paystack is asked before anything new is charged
  select coalesce(jsonb_agg(reference order by created_at), '[]') into verify from (
    select reference, created_at from billing.payment_attempts
     where status in ('created', 'pending', 'unknown') and claimed_until <= p_at
     order by created_at limit 200) v;
  for r in select id from billing.subscriptions where status in ('active', 'past_due') order by account loop
    exit when jsonb_array_length(charges) >= 300;
    one := billing.run_one(r.id, p_at);
    continue when one is null;
    steps := jsonb_set(steps, array[one->>'step'], to_jsonb(coalesce((steps->>(one->>'step'))::int, 0) + 1));
    if one ? 'charge' then charges := charges || jsonb_build_array(one->'charge'); end if;
  end loop;
  with c as (
    update billing.refunds set status = 'sending', claimed_until = p_at + interval '10 minutes', tries = tries + 1, updated_at = p_at
     where (status in ('due', 'failed') and reason <> 'manual' and (next_try_at is null or next_try_at <= p_at))
        or (status = 'sending' and claimed_until <= p_at)
    returning id, reference, amount_minor)
  select coalesce(jsonb_agg(jsonb_build_object('refund', id, 'reference', reference, 'amount_minor', amount_minor)), '[]')
    into refunds from c;
  return jsonb_build_object('verify', verify, 'charges', charges, 'refunds', refunds, 'steps', steps);
end $function$;
