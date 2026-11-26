CREATE OR REPLACE FUNCTION public.api_logins()
 RETURNS TABLE(account_id uuid, sunsynk_username text, status text, linked_at timestamp with time zone, last_ok_at timestamp with time zone, plants jsonb, kind text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  with me as (select auth.uid() u, (select id from billing.accounts where user_id = auth.uid()) acc)
  select a.id, a.username, a.status,
         case when a.kind = 'share' then (select min(x.linked_at) from plants.user_plants x where x.account_id = a.id and x.user_id = me.u)
              else a.linked_at end,
         a.last_ok_at,
         coalesce((select jsonb_agg(jsonb_build_object('plant_id', pu.plant_id, 'plant_name', pu.plant_name,
                     'paused', not exists (select 1 from billing.seats se where se.account = me.acc and se.plant = pu.plant_id
                                              and se.closed_at is null),
                     'linked_at', pu.linked_at,
                     'inverters', (select count(*) from private.inverters i where i.plant_id = pu.plant_id),
                     'share_gone', pu.share_gone_at is not null,
                     'started_at', (select s.started_at from private.plant_alert_state s where s.plant_id = pu.plant_id))
                   order by pu.linked_at, pu.plant_id)
                     from plants.user_plants pu where pu.account_id = a.id and pu.user_id = me.u), '[]'::jsonb),
         a.kind
    from plants.logins a cross join me
   where a.user_id = me.u
      or (a.kind = 'share' and exists (select 1 from plants.user_plants x where x.account_id = a.id and x.user_id = me.u))
   order by 4 desc
$function$;
