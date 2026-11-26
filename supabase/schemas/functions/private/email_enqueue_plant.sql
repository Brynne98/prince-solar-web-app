CREATE OR REPLACE FUNCTION private.email_enqueue_plant(p_plant bigint, p_kind text, p_key text, p_data jsonb, p_pair_key text DEFAULT NULL::text, p_priority smallint DEFAULT 0)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into public.email_queue (user_id, plant_id, kind, key, pair_key, data, priority)
  select pu.user_id, p_plant, p_kind, p_key, p_pair_key, p_data, p_priority
    from public.plant_users pu where pu.plant_id = p_plant
  on conflict do nothing;
$function$;
