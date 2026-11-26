CREATE OR REPLACE FUNCTION public.share_account_set(p_user uuid, p_username text, p_access text, p_expires bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare acc uuid;
begin
  acc := public.account_upsert(p_user, p_username, p_access, p_expires);
  update private.sunsynk_accounts set kind = 'share' where id = acc;
  return acc;
end $function$;
