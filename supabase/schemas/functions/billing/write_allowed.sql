CREATE OR REPLACE FUNCTION billing.write_allowed(p_versions jsonb, p_at timestamp with time zone)
 RETURNS bigint[]
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare
  ok bigint[] := '{}';
  p record;
begin
  for p in select bp.id, bp.version from billing.plants bp
            where bp.id in (select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k)
            order by bp.id for share
  loop
    if p.version = (p_versions->>(p.id::text))::bigint
       and (billing.plant_state(p.id, p_at)->>'read_now')::boolean then
      ok := ok || p.id;
    end if;
  end loop;
  return ok;
end $function$;
