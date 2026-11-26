CREATE OR REPLACE FUNCTION public.my_plant(p_plant bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v bigint;
begin
  -- The server (service_role, or no API request at all) has already decided
  -- which plant it is working on: trust it. auth.role() is null only off the API.
  if p_plant is not null and coalesce(auth.role(), 'service_role') = 'service_role' then
    return p_plant;
  end if;
  if p_plant is null then
    select min(x) into v from public.my_plant_ids() x;
    if v is null then
      raise exception 'no plant linked to this user' using errcode = 'P0002';
    end if;
    return v;
  end if;
  if p_plant in (select public.my_plant_ids()) then
    return p_plant;
  end if;
  raise exception 'plant % is not linked to this user', p_plant using errcode = '42501';
end $function$;
