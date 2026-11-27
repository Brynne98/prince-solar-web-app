CREATE OR REPLACE FUNCTION history.tidy(p_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  update history.import_accounts a set left_at = p_at
    from history.imports i
   where i.id = a.import and i.status = 'open' and a.left_at is null
     and not billing.holds_plant(a.account, i.plant, p_at);
  perform history.stop_import(i.id, case when private.history_deleting(i.plant) then 'deleted' else 'switched_out' end, p_at)
     from history.imports i
    where i.status = 'open'
      and (private.history_deleting(i.plant)
           or not exists (select 1 from history.import_accounts a where a.import = i.id and a.left_at is null));
end $function$;
