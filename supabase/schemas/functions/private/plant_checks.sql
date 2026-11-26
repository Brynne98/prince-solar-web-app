CREATE OR REPLACE FUNCTION private.plant_checks()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p bigint;
  n int := 0;
  sign text;
begin
  for p in select x from public.live_plants() x
            where x % 10 = (floor(extract(epoch from now()) / 60))::bigint % 10 order by x loop
    begin perform public.plant_features_detect(p); exception when others then raise warning 'plant_features_detect %: %', p, sqlerrm; end;
    begin perform public.battery_banks_detect(p); exception when others then raise warning 'battery_banks_detect %: %', p, sqlerrm; end;
    if (select c.batt_positive_means from public.plant_config c where c.plant_id = p) is null then
      sign := (select b.batt_positive_means from plants.brands b where b.code = plants.brand_of(p));
      begin perform public.batt_sign_detect(p, coalesce(sign, 'discharging')); exception when others then raise warning 'batt_sign_detect %: %', p, sqlerrm; end;
    end if;
    n := n + 1;
  end loop;
  return jsonb_build_object('plants', n);
end $function$;
