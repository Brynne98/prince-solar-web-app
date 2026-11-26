CREATE OR REPLACE FUNCTION private.pick_waiting(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  select coalesce((select st.state = 'none' and st.linked > 0 and st.chosen = 0
                     from billing.accounts a cross join lateral billing.account_status(a.id, now()) st
                    where a.user_id = p_user), false)
$function$;
