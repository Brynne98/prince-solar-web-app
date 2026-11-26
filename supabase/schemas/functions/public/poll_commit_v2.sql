CREATE OR REPLACE FUNCTION public.poll_commit_v2(p_versions jsonb, p_account uuid, p_ts bigint, p_readings jsonb, p_strings jsonb, p_agg jsonb, p_meta jsonb, p_inverters jsonb, p_access text, p_expires bigint, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
declare
  ok bigint[];
  out jsonb;
  pl record;
begin
  if not billing.is_live() then
    return public.poll_commit(p_account, p_ts, p_readings, p_strings, p_agg, p_meta, p_inverters, p_access, p_expires);
  end if;
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));
  for pl in select bp.id, bp.history_purged_at is not null as purged from billing.plants bp
             where bp.id in (select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k)
             order by bp.id loop
    if pl.purged then
      perform 1 from billing.plants where id = pl.id for no key update;
    else
      perform 1 from billing.plants where id = pl.id for share;
    end if;
  end loop;
  ok := billing.write_allowed(p_versions, p_at);
  -- the token is saved whatever happens to the readings: the fetch may have refreshed it
  perform set_config('billing.guarded', 'on', true);
  out := public.poll_commit(p_account, p_ts, billing.only_plants(p_readings, ok), billing.only_plants(p_strings, ok),
                            billing.only_plants(p_agg, ok), billing.only_plants(p_meta, ok), p_inverters,
                            p_access, p_expires);
  perform set_config('billing.guarded', 'off', true);
  -- new readings on a deleted plant: it has history again, so the delete date and "History
  -- deleted" go
  update billing.plants set history_purged_at = null
   where history_purged_at is not null and id = any (ok)
     and id in (select (e->>'plant_id')::bigint from jsonb_array_elements(coalesce(p_readings, '[]'::jsonb)) e
                union select (e->>'plant_id')::bigint from jsonb_array_elements(coalesce(p_agg, '[]'::jsonb)) e);
  return out || jsonb_build_object('refused', to_jsonb(array(
    select k::bigint from jsonb_object_keys(coalesce(p_versions, '{}')) k where k::bigint <> all (ok) order by 1)));
end $function$;
