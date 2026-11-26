CREATE OR REPLACE FUNCTION private.require_admin()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'private', 'pg_temp'
AS $function$
begin
  if auth.uid() is null or not exists (select 1 from private.admins where user_id = auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
end $function$;
