CREATE OR REPLACE FUNCTION private.offer_member_skip_tests()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  if exists (select 1 from private.test_users t where t.user_id = new.user_id) then
    return null;
  end if;
  return new;
end $function$;
