CREATE OR REPLACE FUNCTION history.leave(p_plant bigint, p_account uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare imp bigint;
begin
  select i.id into imp from history.imports i where i.plant = p_plant and i.status = 'open' for update;
  if imp is null then return; end if;
  update history.import_accounts set left_at = p_at where import = imp and account = p_account and left_at is null;
  if not exists (select 1 from history.import_accounts a where a.import = imp and a.left_at is null) then
    perform history.stop_import(imp, 'switched_out', p_at);
  end if;
end $function$;
