-- SOLAR-488: 0172's api_link_status, with each plant's linked_at. The cancel window names
-- the plant Free keeps when none is picked: the first linked, as private.billing_drops ranks.
-- Nothing else changes.
create or replace function public.api_link_status()
 returns table(account_id uuid, sunsynk_username text, status text, linked_at timestamptz, last_ok_at timestamptz, plants jsonb, kind text)
 language sql
 security definer
 set search_path to 'public', 'private', 'pg_temp'
as $function$
  with b as (select bl.*, private.billing_drops(bl) drops from private.billing bl where bl.user_id = auth.uid())
  select a.id, a.sunsynk_username, a.status,
         -- the share login: when this user first claimed through it
         case when a.kind = 'share' then (select min(x.linked_at) from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid())
              else a.linked_at end,
         a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                                                        'paused', pu.paused, 'linked_at', pu.linked_at,
                                                        'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                                                        'remove_on', case when pu.plant_id = any (b.plants_to_remove) then b.remove_on
                                                                          when pu.plant_id = any (b.drops) then b.next_billing_date + 30 end,
                                                        'drop', coalesce(pu.plant_id = any (b.drops), false),
                                                        'free_removal', pu.plant_id = any (b.plants_to_remove) and pu.plant_id = any (b.free_removals),
                                                        -- the owner removed the share in SunSynk (0172)
                                                        'share_gone', pu.share_gone_at is not null)
                                    order by pu.linked_at, pu.plant_id)
                     from public.plant_users pu
                     left join b on b.user_id = pu.user_id
                    where pu.account_id = a.id and pu.user_id = auth.uid()),
                  '[]'::jsonb),
         a.kind
    from private.sunsynk_accounts a
   where a.user_id = auth.uid()
      or (a.kind = 'share' and exists (select 1 from public.plant_users x where x.account_id = a.id and x.user_id = auth.uid()))
   order by 4 desc
$function$;
