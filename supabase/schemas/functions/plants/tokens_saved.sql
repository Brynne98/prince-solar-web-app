CREATE OR REPLACE FUNCTION plants.tokens_saved(p_tokens jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  update plants.logins sa
     set access_token = case when (t->>'expires')::bigint >= coalesce(sa.access_expires_at, 0) then t->>'access' else sa.access_token end,
         access_expires_at = greatest((t->>'expires')::bigint, coalesce(sa.access_expires_at, 0)),
         last_ok_at = now(), last_error = null
    from jsonb_array_elements(coalesce(p_tokens, '[]'::jsonb)) t
   where sa.id = (t->>'account')::uuid
$function$;
