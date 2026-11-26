CREATE OR REPLACE PROCEDURE private.purge_plants()
 LANGUAGE plpgsql
AS $procedure$
declare
  ids bigint[];
  p bigint;
  r jsonb;
begin
  select coalesce(array_agg(plant_id order by requested_at, plant_id), '{}') into ids from private.plant_purge;
  foreach p in array ids loop
    begin
      r := private.purge_plant(p, false);
    exception when others then
      -- the plant stays tombstoned for the next run; the others still get done
      raise warning 'purge of plant % failed: %', p, sqlerrm;
      r := null;
    end;
    commit;
    if r is not null then raise notice 'purged plant %: %', p, r; end if;
  end loop;
end $procedure$;
