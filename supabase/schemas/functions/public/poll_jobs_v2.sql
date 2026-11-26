CREATE OR REPLACE FUNCTION public.poll_jobs_v2(p_shard integer, p_shards integer, p_account uuid DEFAULT NULL::uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(plant_id bigint, plant_name text, timezone text, batt_positive_means text, backfill_next text, backfill_until text, backfill_tries integer, temp_next text, temp_tries integer, has_grid boolean, account_id uuid, user_id uuid, username text, access_token text, access_expires_at bigint, plant_version bigint, brand text, vendor_plant_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
begin
  return query
  with pick as (
    select distinct on (r.plant) r.plant, r.lane
      from billing.reading_routes(p_at) r
     order by r.plant, r.via_share, r.since, r.lane
  )
  select p.plant,
         (select lp.plant_name from plants.login_plants lp
           where lp.plant = p.plant and lp.plant_name is not null order by lp.last_seen_at desc nulls last limit 1),
         bp.time_zone, c.batt_positive_means,
         c.backfill_next::text, c.backfill_until::text, coalesce(c.backfill_tries, 0),
         c.temp_next::text, coalesce(c.temp_tries, 0), c.has_grid,
         sa.id, sa.user_id, sa.username, sa.access_token, sa.access_expires_at,
         bp.version, bp.brand, bp.vendor_id
    from pick p
    join plants.logins sa on sa.id = p.lane
    join plants.plants bp on bp.id = p.plant
    left join public.plant_config c on c.plant_id = p.plant
   where case when p_account is not null then sa.id = p_account
              else ('x' || lpad(substr(replace(sa.id::text, '-', ''), 1, 8), 16, '0'))::bit(64)::bigint
                   % greatest(1, p_shards) = p_shard end
   order by p.plant;
end $function$;
