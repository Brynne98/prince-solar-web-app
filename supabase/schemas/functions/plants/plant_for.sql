CREATE OR REPLACE FUNCTION plants.plant_for(p_brand text, p_vendor_id text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare id bigint;
begin
  if p_vendor_id is null or btrim(p_vendor_id) = '' then raise exception 'plant_for: no vendor id' using errcode = '22023'; end if;
  select p.id into id from plants.plants p where p.brand = p_brand and p.vendor_id = p_vendor_id;
  if found then return id; end if;
  insert into plants.plants (brand, vendor_id, time_zone)
  values (p_brand, p_vendor_id, (select m.default_time_zone from billing.markets m order by m.code limit 1))
  on conflict (brand, vendor_id) do nothing
  returning plants.plants.id into id;
  if id is null then   -- a concurrent call made it first
    select p.id into id from plants.plants p where p.brand = p_brand and p.vendor_id = p_vendor_id;
  end if;
  return id;
end $function$;
