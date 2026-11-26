CREATE OR REPLACE FUNCTION plants.link_allowed(p_user uuid, p_brand text, p_username text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((select (billing.account_state(a.id)->>'may_add_login')::boolean
                          or exists (select 1 from plants.logins l where l.account = a.id and l.brand = p_brand
                                        and lower(l.username) = lower(p_username))
                     from billing.accounts a where a.user_id = p_user), true)
$function$;
