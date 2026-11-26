CREATE OR REPLACE FUNCTION private.login_lock(p_logins uuid[], p_status text, p_user uuid DEFAULT NULL::uuid, p_plants bigint[] DEFAULT '{}'::bigint[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare
  x uuid;
  moving uuid[];
begin
  foreach x in array array(select distinct l from unnest(p_logins) l where l is not null order by 1) loop
    perform pg_advisory_xact_lock(1, hashtext(x::text));
  end loop;
  moving := case when p_status is null then '{}'::uuid[]
                 else array(select sa.id from plants.logins sa
                             where sa.id = any (p_logins) and sa.status is distinct from p_status) end;
  perform 1 from billing.accounts a
   where a.id in (select bl.account from plants.logins bl where bl.id = any (moving))
      or a.user_id = p_user
   order by a.id for update;
  perform billing.lock_plants(array(select lp.plant from plants.login_plants lp where lp.login = any (moving))
                              || coalesce(p_plants, '{}'));
end $function$;
