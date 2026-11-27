CREATE OR REPLACE FUNCTION history.cost(p_kind text, p_plant bigint, p_grid_only boolean, p_full boolean)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case p_kind
           when 'totals' then case when p_full then 17 else 3 end
           else greatest(1, (select count(*) from plants.inverter_info i where i.plant_id = p_plant))::integer
                * case when p_kind = 'minutes' then 4 when p_grid_only then 1 else 2 end
         end
$function$;
