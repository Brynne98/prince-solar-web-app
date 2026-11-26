CREATE OR REPLACE FUNCTION public.msg_email_done(p_claim uuid, p_results jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with res as (
    select (e->>'id')::bigint id, coalesce((e->>'code')::int, 0) code, (e->>'retry_s')::int retry_s, e->>'error' err,
           coalesce((e->>'untried')::boolean, false) untried, e->>'skip' skip,
           coalesce((e->>'keep')::boolean, false) keep, (e->>'hold_s')::int hold_s
      from jsonb_array_elements(coalesce(p_results, '[]')) e),
  plan as (
    select o.id, r.code, r.err, r.untried, r.skip, r.keep,
           not r.untried and r.hold_s is not null as held,
           now() + make_interval(secs => greatest(coalesce(r.hold_s, 0), 5)) as hold_at,
           r.code between 200 and 299 as ok,
           r.code in (400, 422) as refused,
           -- Retry-After 0 or past: still 5 s, or one pass would call Resend in a loop
           now() + make_interval(secs => greatest(coalesce(r.retry_s, least(60 * 2 ^ greatest(o.tries - 1, 0), 600)), 5)) as next_at,
           o.expires_at
      from res r
      join msg.outbox o on o.id = r.id and o.claim = p_claim and o.channel = 'email' and o.status = 'queued'),
  -- a hold is neither sent nor refused: the rules below read it as such
  p2 as (
    select p.*, p.held and p.hold_at >= p.expires_at as held_out,
           not p.held and p.ok as ok2, not p.held and p.refused as refused2,
           case when p.held then null else p.skip end as skip2
      from plan p)
  update msg.outbox o
     set status = case when p.untried then 'queued'
                       when p.held then case when p.held_out then 'dropped' else 'queued' end
                       when p.skip2 is not null then 'dropped'
                       when p.ok2 then 'sent'
                       when p.refused2 or p.next_at >= p.expires_at then 'failed'
                       else 'queued' end,
         drop_reason = case when p.held_out then left(coalesce(p.err, 'held'), 200)
                            when p.skip2 is not null and not p.untried then left(p.skip2, 200) else o.drop_reason end,
         not_before = case when p.held then p.hold_at
                           when p.untried or p.skip2 is not null or p.ok2 or p.refused2 then o.not_before else p.next_at end,
         -- a 429, a hold or a row never tried sent nothing: the try is given back
         tries = o.tries - case when (p.untried or p.held or p.code = 429) and o.tries > 0 then 1 else 0 end,
         n429 = o.n429 + (p.code = 429 and not p.untried and not p.held and p.skip2 is null)::int,
         last_429_at = case when p.code = 429 and not p.untried and not p.held and p.skip2 is null then now() else o.last_429_at end,
         last_error = case when p.untried then o.last_error
                           when p.held then left(coalesce(p.err, 'held'), 200)
                           when p.ok2 or p.skip2 is not null then null
                           when not p.refused2 and p.next_at >= p.expires_at then 'too old'
                           else left(coalesce(p.err, 'resend ' || p.code), 200) end,
         done_at = case when p.untried then null
                        when p.held then case when p.held_out then now() end
                        when p.skip2 is not null or p.ok2 or p.refused2 or p.next_at >= p.expires_at then now() end,
         batch_key = case when p.keep and not p.held and (p.untried or (p.skip2 is null and not p.ok2 and not p.refused2
                                                                       and p.next_at < p.expires_at))
                          then o.batch_key end,
         claim = null, claimed_until = null
    from p2 p
   where o.id = p.id
$function$;
