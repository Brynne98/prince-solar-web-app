CREATE OR REPLACE FUNCTION public.share_claim_any(p_user uuid, p_account uuid, p_plant text, p_plant_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  vendor text := btrim(p_plant);   -- the brand's id for the plant (R11)
  v_brand text;
  pid bigint;
  acc uuid;
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  select l.brand into v_brand from plants.logins l where l.id = p_account and l.kind = 'share' and l.status <> 'disabled';
  if not found then raise exception 'share_claim: % is not the share login', p_account; end if;
  acc := billing.account_of(p_user);
  select p.id into pid from plants.plants p where p.brand = v_brand and p.vendor_id = vendor;
  -- the user reads it already: through their own login, or a claim whose share row is live (a
  -- claim with its row missing is repaired below)
  if pid is not null and (exists (select 1 from plants.user_plants u where u.plant_id = pid and u.user_id = p_user
                                     and not u.via_share and u.share_gone_at is null)
                          or (exists (select 1 from plants.claims c where c.plant = pid and c.account = acc)
                              and exists (select 1 from plants.login_plants lp where lp.login = p_account and lp.plant = pid
                                             and lp.gone_at is null))) then
    return jsonb_build_object('result', 'yours', 'plant', pid);
  end if;
  pid := plants.claim(acc, v_brand, vendor, p_plant_name);
  -- a lapsed claim by someone else: its queued mail goes
  delete from public.email_queue q where q.plant_id = pid and q.status = 'queued'
     and q.user_id <> p_user and q.kind like 'share_%';
  return jsonb_build_object('result', 'claimed', 'plant', pid);
end
$function$;
