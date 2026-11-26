CREATE OR REPLACE FUNCTION public.share_sync(p_account uuid, p_plants bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
declare
  now_s bigint := extract(epoch from now())::bigint;
  back int; missing int; gone int := 0;
  ended jsonb;
  g record;
  acc uuid;
begin
  perform pg_advisory_xact_lock_shared(3, 0);  -- waits for a billing run, before any other lock (SOLAR-438)
  perform pg_advisory_xact_lock(1, hashtext(p_account::text));

  -- in the list: a miss is forgotten (a stopped claim waits for its owner's Check)
  update public.plant_users pu set share_missing_at = null
   where pu.account_id = p_account and pu.via_share and pu.plant_id = any (p_plants)
     and pu.share_missing_at is not null and pu.share_gone_at is null;
  get diagnostics back = row_count;

  -- not in the list: first miss noted, so one bad list can't stop a plant
  update public.plant_users pu set share_missing_at = now()
   where pu.account_id = p_account and pu.via_share and pu.share_gone_at is null and pu.share_missing_at is null
     and pu.plant_id <> all (p_plants);
  get diagnostics missing = row_count;

  -- still missing an hour on: stop it, release the claim and tell the owner once
  with e as (
    update public.plant_users pu set share_gone_at = now()
     where pu.account_id = p_account and pu.via_share and pu.share_gone_at is null
       and pu.share_missing_at < now() - interval '50 minutes' and pu.plant_id <> all (p_plants)
    returning pu.user_id, pu.plant_id, pu.plant_name)
  select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'plant_id', plant_id, 'plant_name', plant_name)
                            order by plant_id, user_id), '[]') into ended from e;
  if jsonb_array_length(ended) = 0 then
    return jsonb_build_object('back', back, 'missing', missing, 'gone', 0);
  end if;
  perform 1 from billing.accounts a
   where a.user_id in (select (x->>'user_id')::uuid from jsonb_array_elements(ended) x)
   order by a.id for update;
  perform billing.lock_plants(array(select (x->>'plant_id')::bigint from jsonb_array_elements(ended) x));

  for g in select * from jsonb_to_recordset(ended) as r (user_id uuid, plant_id bigint, plant_name text) loop
    insert into public.email_queue (user_id, plant_id, kind, key, data, priority)
    values (g.user_id, g.plant_id, 'share_removed', 'share_removed:' || g.plant_id || ':' || now_s,
            jsonb_build_object('plants', jsonb_build_array(coalesce(g.plant_name, 'Plant ' || g.plant_id))), 1)
    on conflict do nothing;
    gone := gone + 1;
    acc := billing.account_of(g.user_id, false);
    if acc is not null and exists (select 1 from billing.plant_claims c where c.account = acc and c.plant = g.plant_id) then
      delete from billing.plant_claims where account = acc and plant = g.plant_id;
      update billing.plants set version = version + 1 where id = g.plant_id;
      update billing.accounts set version = version + 1 where id = acc;
      perform billing.log_event(acc, now(), 'share_gone', 'unclaim', null,
                                jsonb_build_object('plants', jsonb_build_array(g.plant_id), 'closed', '[]'::jsonb));
    end if;
  end loop;

  return jsonb_build_object('back', back, 'missing', missing, 'gone', gone);
end $function$;
