CREATE OR REPLACE FUNCTION private.alerts_minute()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  last_done bigint := (select c.value::bigint from public.app_config c where c.key = 'ALERTS_DONE_TS');
  upto bigint := (floor(extract(epoch from now()) / 60) * 60)::bigint - 60;   -- the minute just over
  m bigint;
  n int := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('private.alerts_minute')) then return jsonb_build_object('busy', true); end if;
  m := greatest(coalesce(last_done, upto - 60), upto - 600) + 60;
  while m <= upto loop
    perform public.email_poll_step(m, '[]'::jsonb, array(select distinct a.plant_id from public.agg_minute a where a.ts = m order by 1));
    insert into public.app_config (key, value, note) values ('ALERTS_DONE_TS', m, 'the last minute the alert step ran for (private.alerts_minute)')
    on conflict (key) do update set value = excluded.value;
    n := n + 1;
    m := m + 60;
  end loop;
  return jsonb_build_object('minutes', n, 'upto', upto);
end $function$;
