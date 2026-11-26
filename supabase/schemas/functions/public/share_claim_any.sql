CREATE OR REPLACE FUNCTION public.share_claim_any(p_user uuid, p_account uuid, p_plant bigint, p_plant_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare res text; err text;
begin
  perform pg_advisory_xact_lock_shared(3, 0);
  if billing.is_live() then
    return jsonb_build_object('result', public.share_claim_live(p_user, p_account, p_plant, p_plant_name));
  end if;
  res := public.share_claim(p_user, p_account, p_plant, p_plant_name);
  -- on every result but taken, so a retry repairs a missing copy
  if res <> 'taken' then
    begin
      perform public.billing_links('claim_plant', jsonb_build_object('user', p_user, 'plant', p_plant, 'name', p_plant_name));
    exception when others then
      err := sqlerrm;
    end;
  end if;
  return jsonb_build_object('result', res, 'copy_error', err);
end $function$;
