CREATE OR REPLACE FUNCTION public.client_errors_cap()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if (select count(*) from public.client_errors where user_id = new.user_id and at > now() - interval '1 hour') >= 50 then
    return null; -- silently dropped
  end if;
  new.message := left(new.message, 2000);
  new.stack := left(new.stack, 8000);
  return new;
end $function$;
