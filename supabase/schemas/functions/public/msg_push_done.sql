CREATE OR REPLACE FUNCTION public.msg_push_done(p_claim uuid, p_results jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ids bigint[]; v_ok bigint[]; v_gone bigint[];
begin
  with res as (
    select (e->>'id')::bigint id, coalesce((e->>'code')::int, 0) code, (e->>'retry_s')::int retry_s, e->>'error' err
      from jsonb_array_elements(coalesce(p_results, '[]')) e),
  plan as (
    select s.id, r.code, r.err,
           r.code = 0 or r.code = 429 or r.code >= 500 as again,
           -- Retry-After 0 or past: still 5 s, or one pass would call the device in a loop
           now() + make_interval(secs => greatest(coalesce(r.retry_s, least(30 * 2 ^ greatest(s.tries - 1, 0), 600)), 5)) as next_at,
           o.expires_at
      from res r
      join msg.push_sends s on s.id = r.id and s.claim = p_claim and s.status = 'sending'
      join msg.outbox o on o.id = s.outbox_id),
  upd as (
    update msg.push_sends s
       set status = case when p.code between 200 and 299 then 'sent'
                         when p.code in (404, 410) then 'gone'
                         when p.again and p.next_at < p.expires_at then 'queued'
                         else 'failed' end,
           not_before = case when p.again then p.next_at else s.not_before end,
           sent_at = case when p.code between 200 and 299 then now() end,
           n429 = s.n429 + (p.code = 429)::int,
           last_code = p.code,
           last_error = case when p.code between 200 and 299 then null
                             when p.again and p.next_at >= p.expires_at then 'too old'
                             else left(coalesce(p.err, 'push service ' || p.code), 200) end,
           claim = null, claimed_until = null, updated_at = now()
      from plan p
     where s.id = p.id
    returning s.outbox_id, s.sub_id, s.status)
  select array_agg(distinct u.outbox_id),
         array_agg(u.sub_id) filter (where u.status = 'sent'),
         array_agg(u.sub_id) filter (where u.status = 'gone')
    into v_ids, v_ok, v_gone
    from upd u;

  update public.push_subs ps set last_ok_at = now() where ps.id = any (v_ok);
  delete from public.push_subs ps where ps.id = any (v_gone);
  perform msg.push_settle(v_ids);
end $function$;
