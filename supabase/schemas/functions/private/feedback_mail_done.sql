CREATE OR REPLACE FUNCTION private.feedback_mail_done()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  new.data := jsonb_build_object('id', new.data->'id');
  return new;
end $function$;
