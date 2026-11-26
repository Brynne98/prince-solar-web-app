CREATE OR REPLACE FUNCTION billing.write_allowed_set(p_versions jsonb, p_at timestamp with time zone)
 RETURNS bigint[]
 LANGUAGE plpgsql
 SET search_path TO 'billing', 'pg_temp'
AS $function$
declare ids bigint[];
begin
  ids := array(select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k);
  perform 1 from plants.plants where id = any (ids) order by id for share;
  return array(select bp.id from plants.plants bp
                where bp.id = any (ids)
                  and bp.version = (p_versions->>(bp.id::text))::bigint
                  and bp.id in (select billing.plants_read_now(ids, p_at))
                order by bp.id);
end $function$;
