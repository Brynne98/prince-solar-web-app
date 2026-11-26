CREATE OR REPLACE FUNCTION billing.guard_write(p_plant bigint, p_version bigint, p_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
begin
  if not billing.is_live() then return; end if;
  if p_version is null
     or cardinality(billing.write_allowed(jsonb_build_object(p_plant::text, p_version), p_at)) = 0 then
    raise exception 'plant % is not read now', p_plant using errcode = '55000';
  end if;
end $function$;
