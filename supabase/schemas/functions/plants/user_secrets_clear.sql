CREATE OR REPLACE FUNCTION plants.user_secrets_clear(p_user uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r record;
begin
  for r in select l.id, l.refresh_secret_id from plants.logins l where l.user_id = p_user and l.refresh_secret_id is not null order by l.id loop
    if not exists (select 1 from plants.logins o where o.refresh_secret_id = r.refresh_secret_id and o.user_id <> p_user) then
      delete from vault.secrets s where s.id = r.refresh_secret_id;
    end if;
    update plants.logins set refresh_secret_id = null where id = r.id;
  end loop;
end $function$;
