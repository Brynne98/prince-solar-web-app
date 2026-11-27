CREATE OR REPLACE FUNCTION history.held(p_step text, p_id bigint, p_claim uuid, p_at timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pl bigint; v bigint;
begin
  if p_step = 'totals' then
    select t.plant, t.version into pl, v from history.totals t where t.plant = p_id;
  else
    select d.plant, d.version into pl, v from history.days d where d.id = p_id;
  end if;
  if pl is null then raise exception 'step % is not read now (gone)', p_id using errcode = '55000'; end if;
  perform billing.guard_write(pl, v, p_at);
  if private.history_deleting(pl) then
    raise exception 'plant % is not read now (being deleted)', pl using errcode = '55000';
  end if;
  if p_step = 'totals' then
    perform 1 from history.totals t where t.plant = p_id and t.claim = p_claim and t.claimed_until > p_at for share;
  else
    perform 1 from history.days d where d.id = p_id and d.status = 'queued' and d.claim = p_claim and d.claimed_until > p_at for share;
  end if;
  if not found then raise exception 'plant % is not read now (claim lost)', pl using errcode = '55000'; end if;
  return pl;
end $function$;
