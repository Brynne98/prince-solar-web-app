CREATE OR REPLACE FUNCTION plants.list_ids(p_brand text, p_plants jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', plants.plant_for(p_brand, v), 'vendor_id', v, 'name', e->>'name')
                            order by v), '[]'::jsonb)
    from (select distinct on (coalesce(e->>'vendor_id', e->>'id')) coalesce(e->>'vendor_id', e->>'id') v, e
            from jsonb_array_elements(coalesce(p_plants, '[]'::jsonb)) e
           where coalesce(e->>'vendor_id', e->>'id') is not null) x
$function$;
