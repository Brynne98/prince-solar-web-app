CREATE OR REPLACE FUNCTION public.poll_routes(p_seconds integer[], p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(plant_id bigint, account_id uuid, plant_version bigint, timezone text, batt_positive_means text, has_grid boolean, ends_at timestamp with time zone, read_second integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with pick as (
    select distinct on (r.plant) r.plant, r.lane, r.ends_at
      from billing.reading_routes_set(p_at) r
     order by r.plant, r.via_share, r.since, r.lane
  ), pk as (
    select p.plant, p.lane, p.ends_at, bp.version from pick p join billing.plants bp on bp.id = p.plant
  ), lane_inv as (
    select pk.lane, count(i.sn) as n
      from pk left join private.inverters i on i.plant_id = pk.plant
     group by pk.lane
  ), sec as (
    select pk.*, case when sa.kind = 'share' or li.n > 10 then private.read_second(pk.plant::text)
                      else private.read_second(pk.lane::text) end as s
      from pk
      join private.sunsynk_accounts sa on sa.id = pk.lane
      join lane_inv li on li.lane = pk.lane
  )
  select sec.plant, sec.lane, sec.version, coalesce(c.timezone, 'Africa/Johannesburg'), c.batt_positive_means,
         c.has_grid, sec.ends_at, sec.s
    from sec left join public.plant_config c on c.plant_id = sec.plant
   where sec.s = any (p_seconds)
   order by sec.plant
$function$;
