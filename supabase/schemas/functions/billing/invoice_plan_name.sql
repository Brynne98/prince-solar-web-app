CREATE OR REPLACE FUNCTION billing.invoice_plan_name()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  new.plan_name := coalesce(new.plan_name, (select name from billing.plans where code = new.plan));
  return new;
end $function$;
